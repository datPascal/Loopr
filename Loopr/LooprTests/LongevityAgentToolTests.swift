import AIKit
import Foundation
import Testing
@testable import Loopr

/// A source for the longevity tools. The six older domains come from `FakeAgentSource`. The new rows are plain values,
/// or come from a real `LooprLongevityAgentReader` on a temporary database when `reader` is set. Reads are counted under the
/// name of the Your data domain they belong to, so a test can prove a blocked domain was never touched.
final class LongevityFakeSource: AgentDataSource, @unchecked Sendable {
    let base = FakeAgentSource()
    var reader: LooprLongevityAgentReader?
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var flags: [String: Bool] = [:]
    /// Runs inside every longevity read, before it returns. A test flips a switch here to prove a result is discarded.
    var onRead: (@Sendable (String) -> Void)?

    var protocolRow: AgentProtocolRow? = LongevityFixtures.protocolRow
    var adherenceData: AgentAdherenceData? = LongevityFixtures.adherence
    var experimentRows: [AgentExperimentRow] = LongevityFixtures.experiments
    var stack = LongevityFixtures.stack
    var labsData = LongevityFixtures.labs
    var capacityData = LongevityFixtures.capacity
    var cardio: AgentCardioAgeRow? = LongevityFixtures.cardio
    var blood: AgentBloodAgeRow? = AgentBloodAgeRow(years: 41.2, collectedDay: "2026-09-12")

    private func bump(_ name: String) {
        lock.withLock { counts[name, default: 0] += 1 }
        onRead?(name)
    }
    func count(_ name: String) -> Int { base.count(name) + lock.withLock { counts[name, default: 0] } }
    /// A flag the last read was handed, such as whether sleep readings were allowed for an experiment result.
    func flag(_ name: String) -> Bool? { lock.withLock { flags[name] } }
    private func record(_ name: String, _ value: Bool) { lock.withLock { flags[name] = value } }

    // MARK: The six older domains

    func metricSeries(_ key: MetricKey, from: String, to: String) async throws -> [AgentMetricPoint] { try await base.metricSeries(key, from: from, to: to) }
    func foodDays(from: String, to: String) async throws -> [AgentFoodDay] { try await base.foodDays(from: from, to: to) }
    func trainingEntries(from: String, to: String) async throws -> [AgentTrainingEntry] { try await base.trainingEntries(from: from, to: to) }
    func trainingTemplates() async throws -> [AgentTemplateRow] { try await base.trainingTemplates() }
    func journalDays(from: String, to: String) async throws -> [AgentJournalDay] { try await base.journalDays(from: from, to: to) }
    func journalNotes(from: String, to: String) async throws -> [AgentJournalNote] { try await base.journalNotes(from: from, to: to) }
    func cycleRows(from: String, to: String) async throws -> [AgentCycleRow] { try await base.cycleRows(from: from, to: to) }
    func visiblePatterns() async throws -> [AgentPatternRow] { try await base.visiblePatterns() }

    // MARK: Longevity

    func activeProtocol() async throws -> AgentProtocolRow? {
        bump("journalAnswers")
        if let reader { return try await reader.activeProtocol() }
        return protocolRow
    }
    func adherence(from: String, to: String, today: String) async throws -> AgentAdherenceData? {
        bump("journalAnswers")
        if let reader { return try await reader.adherence(from: from, to: to, today: today) }
        return adherenceData
    }
    func experiments(from: String, to: String, today: String, withResults: Bool) async throws -> [AgentExperimentRow] {
        bump("journalAnswers"); record("experimentResults", withResults)
        if let reader { return try await reader.experiments(from: from, to: to, today: today, withResults: withResults) }
        return experimentRows.map { row in
            AgentExperimentRow(id: row.id, title: row.title, intervention: row.intervention, ruleKey: row.ruleKey, design: row.design,
                designLength: row.designLength, washout: row.washout, minimumNightsPerArm: row.minimumNightsPerArm, plannedNights: row.plannedNights,
                outcomeKey: row.outcomeKey, outcomeTitle: row.outcomeTitle, outcomeUnit: row.outcomeUnit, outcomeBenefit: row.outcomeBenefit,
                startDay: row.startDay, status: row.status, endDay: row.endDay, stoppedEarly: row.stoppedEarly, nightsCompleted: row.nightsCompleted,
                result: withResults ? row.result : nil)
        }
    }
    func stackDoses(from: String, to: String) async throws -> AgentStackData {
        bump("supplements")
        if let reader { return try await reader.stackDoses(from: from, to: to) }
        return stack
    }
    func labs(from: String, to: String) async throws -> AgentLabsData {
        bump("labs")
        if let reader { return try await reader.labs(from: from, to: to) }
        return labsData
    }
    func capacity(from: String, to: String, today: String, withBandMinutes: Bool, withTargets: Bool) async throws -> AgentCapacityData {
        bump("training"); record("capacityBand", withBandMinutes); record("capacityTargets", withTargets)
        if let reader { return try await reader.capacity(from: from, to: to, today: today, withBandMinutes: withBandMinutes, withTargets: withTargets) }
        // Like the real reader: no zone minutes or targets unless they were allowed.
        return AgentCapacityData(results: capacityData.results, goals: capacityData.goals, weeks: capacityData.weeks.map { week in
            AgentWeeklyDoseRow(week: week.week, firstDay: week.firstDay, lastDay: week.lastDay,
                zone2Minutes: withBandMinutes ? week.zone2Minutes : nil, zone2Target: withTargets ? week.zone2Target : nil,
                hardMinutes: withBandMinutes ? week.hardMinutes : nil, hardTarget: withTargets ? week.hardTarget : nil,
                strengthSessions: week.strengthSessions, strengthTarget: withTargets ? week.strengthTarget : nil,
                mobilitySessions: week.mobilitySessions, mobilityTarget: withTargets ? week.mobilityTarget : nil,
                bandDaysWithData: withBandMinutes ? week.bandDaysWithData : 0, bandDaysInWeek: week.bandDaysInWeek)
        })
    }
    func cardioAge(today: String) async throws -> AgentCardioAgeRow? {
        bump("metrics")
        if let reader { return try await reader.cardioAge(today: today) }
        return cardio
    }
    func bloodAge() async throws -> AgentBloodAgeRow? {
        bump("labs")
        if let reader { return try await reader.bloodAge() }
        return blood
    }
}

/// Rows with every field a tool prints.
enum LongevityFixtures {
    static let protocolRow = AgentProtocolRow(name: "Sleep first", version: 3, versionDay: "2026-10-01", rules: [
        AgentProtocolRuleRow(key: "bed-before-2300", title: "In bed before 23:00", group: "sleep", source: "band", targetKind: "atMost",
                             targetMetric: "bedtime", targetValue: 1_380, targetUnit: "min", time: "23:00", evening: false),
        AgentProtocolRuleRow(key: "magnesium", title: "Magnesium", group: "supplements", source: "manual", targetKind: "done",
                             targetMetric: nil, targetValue: nil, targetUnit: nil, time: "21:30", evening: true),
    ], versions: [AgentProtocolVersionRow(number: 1, day: "2026-08-01"), AgentProtocolVersionRow(number: 2, day: "2026-09-10"),
                  AgentProtocolVersionRow(number: 3, day: "2026-10-01")])

    static let adherence = AgentAdherenceData(protocolName: "Sleep first", days: [
        AgentAdherenceDay(day: "2026-10-14", version: 3, checks: [
            AgentAdherenceCheck(ruleKey: "bed-before-2300", title: "In bed before 23:00", state: "kept"),
            AgentAdherenceCheck(ruleKey: "magnesium", title: "Magnesium", state: "kept")]),
        AgentAdherenceDay(day: "2026-10-15", version: 3, checks: [
            AgentAdherenceCheck(ruleKey: "bed-before-2300", title: "In bed before 23:00", state: "missed"),
            AgentAdherenceCheck(ruleKey: "magnesium", title: "Magnesium", state: "unknown")]),
        AgentAdherenceDay(day: "2026-10-16", version: 3, checks: [
            AgentAdherenceCheck(ruleKey: "bed-before-2300", title: "In bed before 23:00", state: "pending"),
            AgentAdherenceCheck(ruleKey: "magnesium", title: "Magnesium", state: "pending")]),
    ])

    private static func experiment(_ id: String, status: String, result: AgentExperimentResult?) -> AgentExperimentRow {
        AgentExperimentRow(id: id, title: "Magnesium glycinate", intervention: "magnesium", ruleKey: "magnesium", design: "blocks", designLength: 7,
            washout: 1, minimumNightsPerArm: 5, plannedNights: 28, outcomeKey: "deepSleepMinutes", outcomeTitle: "Deep sleep", outcomeUnit: "min",
            outcomeBenefit: "higher", startDay: "2026-09-01", status: status, endDay: status == "running" ? nil : "2026-09-28", stoppedEarly: false,
            nightsCompleted: status == "running" ? 6 : 28, result: result)
    }
    static let experiments: [AgentExperimentRow] = [
        experiment("exp-running", status: "running", result: AgentExperimentResult(state: "tooEarlyToSay", label: nil, onNights: 3, offNights: 2,
                                                                                    difference: nil, rangeFrom: nil, rangeTo: nil)),
        experiment("exp-clear", status: "finished", result: AgentExperimentResult(state: "result", label: "Clear", onNights: 11, offNights: 10,
                                                                                   difference: 12.44, rangeFrom: 5.1, rangeTo: 19.8)),
        experiment("exp-undecided", status: "finished", result: AgentExperimentResult(state: "notCalled", label: nil, onNights: 9, offNights: 9,
                                                                                       difference: 3.1, rangeFrom: -8, rangeTo: 14)),
    ]

    static let stack = AgentStackData(
        supplements: [AgentStackDose(day: "2026-10-15", name: "D3", dose: "2000 IU", slot: "morning", status: "taken", at: "08:05"),
                      AgentStackDose(day: "2026-10-15", name: "D3", dose: "2000 IU", slot: "evening", status: "skipped", at: "21:40"),
                      AgentStackDose(day: "2026-10-16", name: "D3", dose: "2000 IU", slot: "morning", status: "notRecorded", at: nil)],
        medication: [AgentStackDose(day: "2026-10-15", name: "Ramipril", dose: "5 mg", slot: "morning", status: "taken", at: "08:06")])

    static let labs = AgentLabsData(reports: [
        AgentLabReportRow(id: "report-1", day: "2026-09-12", labName: "Labor Berlin", fasting: true, values: [
            AgentLabValueRow(id: "v1", name: "Apolipoprotein B", markerKey: "apob", assay: nil, value: "78", unit: "mg/dL", rangeMin: "40", rangeMax: "90",
                             rangeText: nil, flag: nil, entry: "typed", needsReview: false),
            AgentLabValueRow(id: "v2", name: "C-reactive protein", markerKey: "crp", assay: "hs-CRP", value: "0.60", unit: "mg/L", rangeMin: nil, rangeMax: nil,
                             rangeText: "<5.0", flag: "H", entry: "scan", needsReview: true)]),
    ], clocks: [AgentLabClockRow(id: "clock-1", name: "DunedinPACE", value: "0.92", unit: nil, labName: "TruDiagnostic", day: "2026-09-14")],
       otherDays: ["2026-03-02"])

    static let capacity = AgentCapacityData(
        results: [AgentCapacityResultRow(id: "cap-1", test: "grip", title: "Grip", value: 41.5, unit: "kg", side: "left", day: "2026-10-12", source: "typed"),
                  AgentCapacityResultRow(id: "cap-2", test: "dead_hang", title: "Dead hang", value: 48, unit: "s", side: nil, day: "2026-10-12", source: "timed")],
        goals: [AgentCapacityGoalRow(test: "grip", title: "Grip", targetValue: 30, unit: "kg", targetAge: 85, setDay: "2026-09-01")],
        weeks: [AgentWeeklyDoseRow(week: "2026-W42", firstDay: "2026-10-12", lastDay: "2026-10-18", zone2Minutes: 95, zone2Target: 150, hardMinutes: 22,
                                   hardTarget: 30, strengthSessions: 2, strengthTarget: 3, mobilitySessions: 1, mobilityTarget: 2,
                                   bandDaysWithData: 4, bandDaysInWeek: 7)])

    static let cardio = AgentCardioAgeRow(available: true, years: 38.4, label: nil, vo2Max: 46.2, vo2MaxSource: "Apple Health", day: "2026-10-16")
}

/// What each longevity tool returns for rows it was handed.
@Suite(.serialized)
struct LongevityAgentToolTests {
    private let suite: AgentFixtures.Suite = { let s = AgentFixtures.Suite(); s.setOnly(Set(AgentDataDomain.allCases)); return s }()
    private let source = LongevityFakeSource()

    private func executor(_ source: LongevityFakeSource? = nil, session: AgentToolSession = AgentToolSession()) -> AgentToolExecutor {
        AgentToolExecutor(readers: AgentReaders(gate: AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: source ?? self.source),
                          proposals: nil, maker: nil, session: session, conversationID: UUID(), messageID: UUID(),
                          now: AgentFixtures.now, timeZone: AgentFixtures.zone)
    }
    private func run(_ name: String, _ arguments: [String: Any] = [:], session: AgentToolSession = AgentToolSession()) async -> AgentToolOutcome {
        await executor(session: session).execute(AgentFixtures.call(name, arguments))
    }
    private func object(_ outcome: AgentToolOutcome) throws -> [String: Any] {
        #expect(!outcome.isError && !outcome.denied, "\(outcome.content)")
        return try #require(JSONSerialization.jsonObject(with: Data(outcome.content.utf8)) as? [String: Any])
    }

    // MARK: Protocol

    @Test func theProtocolToolListsRulesWithTargetsTimesSourcesGroupsAndVersions() async throws {
        let json = try object(await run(AgentToolName.getProtocol))
        let protocolObject = try #require(json["protocol"] as? [String: Any])
        #expect(protocolObject["name"] as? String == "Sleep first" && protocolObject["version"] as? Int == 3)
        let rules = try #require(protocolObject["rules"] as? [[String: Any]])
        #expect(rules.count == 2)
        let bed = rules[0]
        #expect(bed["key"] as? String == "bed-before-2300" && bed["group"] as? String == "sleep" && bed["checkedBy"] as? String == "band")
        #expect(bed["target"] as? String == "atMost" && bed["value"] as? Double == 1_380 && bed["time"] as? String == "23:00" && bed["evening"] as? Bool == false)
        #expect(rules[1]["target"] as? String == "done" && rules[1]["value"] == nil && rules[1]["evening"] as? Bool == true)
        let versions = try #require(json["versions"] as? [[String: Any]])
        #expect(versions.map { $0["number"] as? Int } == [1, 2, 3])
        #expect(versions.map { $0["saved"] as? String } == ["2026-08-01", "2026-09-10", "2026-10-01"])
    }

    @Test func withNoProtocolTheToolSaysSoAndInventsNone() async throws {
        let empty = LongevityFakeSource(); empty.protocolRow = nil; empty.adherenceData = nil
        let json = try object(await executor(empty).execute(AgentFixtures.call(AgentToolName.getProtocol)))
        #expect(json["protocol"] is NSNull)
        #expect((json["note"] as? String)?.contains("no active Protocol") == true)
        let adherence = try object(await executor(empty).execute(AgentFixtures.call(AgentToolName.getAdherence)))
        #expect(adherence["protocol"] is NSNull && adherence["days"] == nil)
    }

    // MARK: Adherence

    @Test func adherenceListsEachStatePerDayAndTheKeptShareOfDecidedRules() async throws {
        let json = try object(await run(AgentToolName.getAdherence, ["from": "2026-10-14", "to": "2026-10-16"]))
        let days = try #require(json["days"] as? [[String: Any]])
        #expect(days.count == 3)
        #expect(days[0]["kept"] as? [String] == ["bed-before-2300", "magnesium"] && days[0]["keptShare"] as? Double == 1)
        // One kept, none decided besides it: pending and unknown rules are not misses and stay out of the share.
        #expect(days[1]["missed"] as? [String] == ["bed-before-2300"] && days[1]["unknown"] as? [String] == ["magnesium"])
        #expect(days[1]["keptShare"] as? Double == 0)
        #expect(days[2]["pending"] as? [String] == ["bed-before-2300", "magnesium"] && days[2]["keptShare"] == nil, "a day with nothing decided has no share")
        // Across the range two rules were kept and one was missed. The two pending and the unknown rule are not decided.
        #expect(json["decidedRules"] as? Int == 3 && json["keptRules"] as? Int == 2 && json["keptShare"] as? Double == 0.67)
        let rules = try #require(json["rules"] as? [[String: Any]])
        #expect(rules.map { $0["key"] as? String } == ["bed-before-2300", "magnesium"])
    }

    @Test func adherenceRangesFollowTheSameLimitsAsEveryOtherTool() async {
        let tooLong = await run(AgentToolName.getAdherence, ["from": "2026-05-01", "to": "2026-10-16"])
        #expect(tooLong.isError && tooLong.content.contains("at most 120"))
        let future = await run(AgentToolName.getAdherence, ["to": "2026-10-20"])
        #expect(future.isError)
        let fine = await run(AgentToolName.getAdherence, ["from": "2026-06-19", "to": "2026-10-16"])   // exactly 120 days
        #expect(!fine.isError)
    }

    // MARK: Experiments

    @Test func anExperimentReportsOnlyTheResultItHas() async throws {
        let json = try object(await run(AgentToolName.getExperiments))
        let rows = try #require(json["experiments"] as? [[String: Any]])
        #expect(rows.count == 3)
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in (row["id"] as? String).map { ($0, row) } })

        let running = try #require(byID["exp-running"])
        #expect(running["running"] as? Bool == true && running["status"] as? String == "running" && running["endDay"] == nil)
        let early = try #require(running["result"] as? [String: Any])
        #expect(early["state"] as? String == "tooEarlyToSay")
        #expect(early["label"] == nil && early["difference"] == nil && early["likelyRange"] == nil, "no number before there is a result")

        let clear = try #require(byID["exp-clear"]?["result"] as? [String: Any])
        #expect(clear["label"] as? String == "Clear" && clear["difference"] as? Double == 12.44)
        #expect(clear["likelyRange"] as? [Double] == [5.1, 19.8] && clear["unit"] as? String == "min")

        let undecided = try #require(byID["exp-undecided"]?["result"] as? [String: Any])
        #expect(undecided["state"] as? String == "notCalled" && undecided["label"] == nil && undecided["difference"] == nil && undecided["likelyRange"] == nil,
                "a difference without a label is not a result")

        let design = try #require(byID["exp-clear"]?["design"] as? [String: Any])
        #expect(design["kind"] as? String == "blocks" && design["length"] as? Int == 7 && design["washoutNights"] as? Int == 1)
        let outcome = try #require(byID["exp-clear"]?["outcome"] as? [String: Any])
        #expect(outcome["metric"] as? String == "deepSleepMinutes" && outcome["fixedOnDay1"] as? Bool == true && outcome["betterWhen"] as? String == "higher")
    }

    @Test func aLabelledRowWithoutItsNumbersIsNotShownAsAResult() async throws {
        let odd = LongevityFakeSource()
        odd.experimentRows = [LongevityFixtures.experiments[1]].map { row in
            AgentExperimentRow(id: row.id, title: row.title, intervention: row.intervention, ruleKey: row.ruleKey, design: row.design, designLength: row.designLength,
                washout: row.washout, minimumNightsPerArm: row.minimumNightsPerArm, plannedNights: row.plannedNights, outcomeKey: row.outcomeKey,
                outcomeTitle: row.outcomeTitle, outcomeUnit: row.outcomeUnit, outcomeBenefit: row.outcomeBenefit, startDay: row.startDay, status: row.status,
                endDay: row.endDay, stoppedEarly: row.stoppedEarly, nightsCompleted: row.nightsCompleted,
                result: AgentExperimentResult(state: "result", label: "Strong", onNights: 10, offNights: 10, difference: nil, rangeFrom: nil, rangeTo: nil))
        }
        let json = try object(await executor(odd).execute(AgentFixtures.call(AgentToolName.getExperiments)))
        let result = try #require((json["experiments"] as? [[String: Any]])?.first?["result"] as? [String: Any])
        #expect(result["label"] == nil && result["state"] as? String == "notCalled")
    }

    @Test func withoutBandMetricsNoResultIsComputedOrShown() async throws {
        suite.set(.metrics, false)
        let json = try object(await run(AgentToolName.getExperiments))
        #expect(source.flag("experimentResults") == false, "the reader was told sleep readings are off")
        let rows = try #require(json["experiments"] as? [[String: Any]])
        #expect(rows.count == 3 && rows.allSatisfy { $0["result"] == nil })
        #expect(json["resultsWithheld"] as? String == "Band metrics and sleep is off in Your data, so Ask did not read it.")
    }

    // MARK: Supplements

    @Test func supplementsListTicksPerDayAndNothingMoreThanTheSnapshot() async throws {
        let json = try object(await run(AgentToolName.getSupplements, ["from": "2026-10-15", "to": "2026-10-16"]))
        let supplements = try #require(json["supplements"] as? [[String: Any]])
        #expect(supplements.map { $0["day"] as? String } == ["2026-10-15", "2026-10-16"])
        let doses = try #require(supplements[0]["doses"] as? [[String: Any]])
        #expect(doses.map { $0["status"] as? String } == ["taken", "skipped"] && doses[0]["at"] as? String == "08:05")
        let later = try #require((supplements[1]["doses"] as? [[String: Any]])?.first)
        #expect(later["status"] as? String == "notRecorded" && later["at"] == nil)
        let medication = try #require(json["medication"] as? [[String: Any]])
        #expect(((medication.first?["doses"] as? [[String: Any]])?.first?["name"] as? String) == "Ramipril")
        #expect((json["note"] as? String)?.contains("not a miss") == true)
    }

    // MARK: Blood tests

    @Test func labsReturnPrintedValuesAndNoJudgementBeyondTheLabsOwnFlag() async throws {
        let outcome = await run(AgentToolName.getLabs, ["from": "2026-09-01", "to": "2026-09-30"])
        let json = try object(outcome)
        let reports = try #require(json["reports"] as? [[String: Any]])
        var values = try #require(reports.first?["values"] as? [[String: Any]])
        #expect(values.map { $0["value"] as? String } == ["78", "0.60"], "the digits the lab printed")
        #expect(values[0]["rangeMin"] as? String == "40" && values[0]["rangeMax"] as? String == "90" && values[0]["flag"] == nil)
        #expect(values[1]["rangeText"] as? String == "<5.0" && values[1]["flag"] as? String == "H" && values[1]["needsReview"] as? Bool == true)
        #expect(json["otherReportDays"] as? [String] == ["2026-03-02"])
        #expect((json["clockResults"] as? [[String: Any]])?.first?["clock"] as? String == "DunedinPACE")

        // Take the lab's own flag out, then no judging word is left anywhere in what was sent.
        for index in values.indices { values[index]["flag"] = nil }
        var stripped = json
        stripped["reports"] = [["values": values]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: stripped), as: UTF8.self)
        let judging = try Regex(#"(?i)\b(normal|abnormal|high|low|optimal|healthy|unhealthy|good|bad|elevated|deficient)\b"#)
        #expect(text.firstMatch(of: judging) == nil, "found a judging word in \(text)")
    }

    // MARK: Capacity

    @Test func capacityReturnsResultsGoalsAndTheWeeklyDose() async throws {
        let json = try object(await run(AgentToolName.getCapacity, ["from": "2026-10-10", "to": "2026-10-16"]))
        let results = try #require(json["results"] as? [[String: Any]])
        #expect(results.map { $0["test"] as? String } == ["grip", "dead_hang"] && results[0]["side"] as? String == "left" && results[1]["side"] == nil)
        let goal = try #require((json["goals"] as? [[String: Any]])?.first)
        #expect(goal["targetAtAge"] as? Int == 85 && goal["target"] as? Double == 30)
        let week = try #require((json["weeklyDose"] as? [[String: Any]])?.first)
        #expect(week["week"] as? String == "2026-W42" && week["zone2Minutes"] as? Double == 95 && week["zone2Target"] as? Double == 150)
        #expect(week["strengthSessions"] as? Int == 2 && week["mobilityTarget"] as? Int == 2 && week["bandDaysWithData"] as? Int == 4)
        #expect(source.flag("capacityBand") == true && source.flag("capacityTargets") == true)
    }

    @Test func capacityLeavesOutZoneMinutesAndTargetsWhenTheirSwitchesAreOff() async throws {
        suite.set(.metrics, false); suite.set(.journalAnswers, false)
        let json = try object(await run(AgentToolName.getCapacity, ["from": "2026-10-10", "to": "2026-10-16"]))
        let week = try #require((json["weeklyDose"] as? [[String: Any]])?.first)
        #expect(week["zone2Minutes"] == nil && week["hardMinutes"] == nil && week["zone2Target"] == nil && week["strengthTarget"] == nil)
        #expect(week["strengthSessions"] as? Int == 2, "sessions are Training and still read")
        let note = try #require(json["note"] as? String)
        #expect(note.contains("Band metrics and sleep is off") && note.contains("Journal answers is off"))
        #expect(source.flag("capacityBand") == false && source.flag("capacityTargets") == false)
    }

    // MARK: Ages

    @Test func agesNeverReturnALooprAge() async throws {
        let outcome = await run(AgentToolName.getAges)
        let json = try object(outcome)
        let loopr = try #require(json["looprAge"] as? [String: Any])
        #expect(Set(loopr.keys) == ["available", "note"] && loopr["available"] as? Bool == false)
        #expect(loopr["note"] as? String == "Loopr Age is not available.")
        #expect(!outcome.content.contains("looprAgeYears"))
        // Cardio Age and blood age have values, and nothing else on the page is a Loopr Age.
        let cardio = try #require(json["cardioAge"] as? [String: Any])
        #expect(cardio["available"] as? Bool == true && cardio["years"] as? Double == 38.4 && cardio["vo2Max"] as? Double == 46.2)
        #expect(cardio["vo2MaxSource"] as? String == "Apple Health" && (cardio["method"] as? String)?.contains("reference curve") == true)
        let blood = try #require(json["bloodAge"] as? [String: Any])
        #expect(blood["available"] as? Bool == true && blood["years"] as? Double == 41.2)
    }

    @Test func aLooprAgeStaysUnavailableEvenWhenEveryOtherAgeHasAValue() async throws {
        let json = try object(await run(AgentToolName.getAges))
        let years = ["cardioAge", "bloodAge"].compactMap { (json[$0] as? [String: Any])?["years"] as? Double }
        #expect(years.count == 2)
        #expect((json["looprAge"] as? [String: Any])?["years"] == nil)
    }

    @Test func bloodAgeIsNotAvailableWhenNothingComputesIt() async throws {
        let none = LongevityFakeSource(); none.blood = nil
        let json = try object(await executor(none).execute(AgentFixtures.call(AgentToolName.getAges)))
        let blood = try #require(json["bloodAge"] as? [String: Any])
        #expect(blood["available"] as? Bool == false && blood["note"] as? String == "Blood age is not available.")
        #expect(blood["years"] == nil)
    }

    @Test func bloodAgeIsReadOnlyWhileBloodTestsIsOn() async throws {
        suite.set(.labs, false)
        let json = try object(await run(AgentToolName.getAges))
        let blood = try #require(json["bloodAge"] as? [String: Any])
        #expect(blood["available"] as? Bool == false && blood["years"] == nil)
        #expect(blood["note"] as? String == "Blood tests is off in Your data, so Ask did not read it.")
        #expect(source.count("labs") == 0, "the blood test reader was never called")
        #expect((json["cardioAge"] as? [String: Any])?["years"] as? Double == 38.4, "Cardio Age rests on band metrics alone")
    }

    @Test func cardioAgeIsReadOnlyWhileBandMetricsIsOn() async throws {
        suite.set(.metrics, false)
        let json = try object(await run(AgentToolName.getAges))
        let cardio = try #require(json["cardioAge"] as? [String: Any])
        #expect(cardio["available"] as? Bool == false && cardio["years"] == nil && cardio["vo2Max"] == nil)
        #expect(source.count("metrics") == 0)
        #expect((json["bloodAge"] as? [String: Any])?["years"] as? Double == 41.2)
    }

    @Test func agesWithBothSwitchesOffIsRefused() async {
        suite.set(.metrics, false); suite.set(.labs, false)
        let outcome = await run(AgentToolName.getAges)
        #expect(outcome.denied && outcome.isError)
        #expect(outcome.content == "Band metrics and sleep is off in Your data, so Ask did not read it.")
        #expect(source.count("metrics") == 0 && source.count("labs") == 0)
    }

    // MARK: Sources

    @Test func eachToolLeavesASourceNamingWhatItRead() async throws {
        let session = AgentToolSession()
        for name in [AgentToolName.getProtocol, AgentToolName.getAdherence, AgentToolName.getExperiments, AgentToolName.getSupplements,
                     AgentToolName.getLabs, AgentToolName.getCapacity, AgentToolName.getAges] {
            _ = await run(name, ["from": "2026-10-01", "to": "2026-10-16"], session: session)
        }
        let sources = await session.artifacts.sources
        #expect(sources.count == 7)
        let byLabel = Dictionary(uniqueKeysWithValues: sources.map { ($0.label, $0) })
        #expect(byLabel["Protocol"]?.domain == .journalAnswers && byLabel["Protocol"]?.count == 2)
        #expect(byLabel["Experiments"]?.count == 3)
        #expect(byLabel["Supplements and medication"]?.domain == .supplements)
        #expect(byLabel["Blood tests"]?.domain == .labs && byLabel["Capacity and dose"]?.domain == .training)
        #expect(byLabel["Ages"]?.domain == .metrics)
        #expect(AgentSourceCopy.text(try #require(byLabel["Protocol"])) == "Protocol · 2 rules")
        #expect(AgentSourceCopy.text(try #require(byLabel["Blood tests"])) == "Blood tests · 2 reports")
    }
}
