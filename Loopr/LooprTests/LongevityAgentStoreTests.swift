import AIKit
import AnalyticsKit
import DataKit
import DomainKit
import FoodKit
import Foundation
import RoutineKit
import StorageKit
import Testing
import TrainKit
@testable import Loopr

/// The longevity tools against the real stores on a temporary database, so what Ask sends is what the stores hold and nothing more.
@Suite(.serialized)
struct LongevityAgentStoreTests {
    private let suite: AgentFixtures.Suite = { let s = AgentFixtures.Suite(); s.setOnly(Set(AgentDataDomain.allCases)); return s }()
    /// Sat 10 Oct 2026, 12:00 in Perth, six days before the fixture's today.
    private let tenth = AgentFixtures.now.addingTimeInterval(-6 * 86_400)

    private struct Rig {
        let database: StorageDatabase
        let root: URL
        let source: LongevityFakeSource
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeRig(history: any MetricHistoryProviding = EmptyMetricHistoryProvider()) throws -> Rig {
        let (database, root) = try AgentFixtures.temporaryDatabase()
        let source = LongevityFakeSource()
        source.reader = LooprLongevityAgentReader(database: database, history: history, timeZone: AgentFixtures.zone)
        return Rig(database: database, root: root, source: source)
    }
    private func run(_ rig: Rig, _ name: String, _ arguments: [String: Any] = [:]) async -> AgentToolOutcome {
        let executor = AgentToolExecutor(readers: AgentReaders(gate: AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: rig.source),
                                         proposals: nil, maker: nil, session: AgentToolSession(), conversationID: UUID(), messageID: UUID(),
                                         now: AgentFixtures.now, timeZone: AgentFixtures.zone)
        return await executor.execute(AgentFixtures.call(name, arguments))
    }
    private func object(_ outcome: AgentToolOutcome) throws -> [String: Any] {
        #expect(!outcome.isError && !outcome.denied, "\(outcome.content)")
        return try #require(JSONSerialization.jsonObject(with: Data(outcome.content.utf8)) as? [String: Any])
    }
    private func dec(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    private func rules() -> [ProtocolRule] {
        [ProtocolRule(key: "bed", title: "In bed before 23:00", group: .sleep,
                      target: RuleTarget(kind: .atMost, metric: "bedtime", value: 1_380, unit: "min"), timeOfDayMinutes: 1_380, source: .band),
         ProtocolRule(key: "magnesium", title: "Magnesium", group: .supplements, source: .manual, isEvening: true, rebuttal: "I always skip this one"),
         ProtocolRule(key: "zone2", title: "Zone 2", group: .fitness,
                      target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 150, unit: "min/week"), source: .band)]
    }
    @discardableResult
    private func makeProtocol(_ rig: Rig) throws -> RoutineProtocol {
        let store = RoutineStore(database: rig.database)
        let routine = RoutineProtocol(name: "Sleep first", author: "Dr. Secret Author", createdAt: tenth)
        try store.createProtocol(routine, rules: rules(), note: "first secret version note")
        return routine
    }
    private func check(_ key: RuleKey, _ day: String, _ state: CheckState, version: Int = 1, source: CheckSource = .band) throws -> RuleCheck {
        try RuleCheck(ruleKey: key, day: DayIdentity(routineDayKey: day)!, version: version, state: state, source: source, recordedAt: AgentFixtures.now)
    }

    // MARK: Protocol

    @Test func theProtocolToolSendsRulesAndVersionNumbersButNoNotesRebuttalsOrAuthor() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let routine = try makeProtocol(rig)
        try RoutineStore(database: rig.database).saveVersion(protocolID: routine.id, rules: rules(), note: "second secret version note",
                                                              at: AgentFixtures.now.addingTimeInterval(-2 * 86_400))
        let outcome = await run(rig, AgentToolName.getProtocol)
        let json = try object(outcome)
        let protocolObject = try #require(json["protocol"] as? [String: Any])
        #expect(protocolObject["name"] as? String == "Sleep first" && protocolObject["version"] as? Int == 2 && protocolObject["versionSaved"] as? String == "2026-10-14")
        let sent = try #require(protocolObject["rules"] as? [[String: Any]])
        #expect(sent.map { $0["key"] as? String } == ["bed", "magnesium", "zone2"])
        #expect(sent[0]["time"] as? String == "23:00" && sent[0]["checkedBy"] as? String == "band" && sent[0]["group"] as? String == "sleep")
        #expect(sent[1]["evening"] as? Bool == true && sent[1]["target"] as? String == "done")
        let versions = try #require(json["versions"] as? [[String: Any]])
        #expect(versions.map { $0["number"] as? Int } == [1, 2] && versions.map { $0["saved"] as? String } == ["2026-10-10", "2026-10-14"])
        for secret in ["first secret version note", "second secret version note", "I always skip this one", "Dr. Secret Author"] {
            #expect(!outcome.content.contains(secret), "\(secret) reached the model")
        }
    }

    @Test func adherenceReadsStoredChecksAndNeverTurnsAGapIntoAMiss() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let routine = try makeProtocol(rig)
        let store = RoutineStore(database: rig.database)
        try store.saveVersion(protocolID: routine.id, rules: rules(), note: nil, at: AgentFixtures.now.addingTimeInterval(-2 * 86_400))
        try store.recordCheck(check("bed", "2026-10-12", .kept), protocolID: routine.id)
        try store.recordCheck(check("magnesium", "2026-10-12", .missed, source: .manual), protocolID: routine.id)
        try store.recordCheck(check("bed", "2026-10-14", .kept, version: 2), protocolID: routine.id)

        let json = try object(await run(rig, AgentToolName.getAdherence, ["from": "2026-10-09", "to": "2026-10-16"]))
        let days = try #require(json["days"] as? [[String: Any]])
        #expect(days.map { $0["day"] as? String } == ["2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16"],
                "nothing is listed for 9 Oct, before the Protocol began")
        let byDay = Dictionary(uniqueKeysWithValues: days.compactMap { day in (day["day"] as? String).map { ($0, day) } })
        let twelfth = try #require(byDay["2026-10-12"])
        #expect(twelfth["kept"] as? [String] == ["bed"] && twelfth["missed"] as? [String] == ["magnesium"] && twelfth["unknown"] as? [String] == ["zone2"])
        #expect(twelfth["keptShare"] as? Double == 0.5 && twelfth["version"] as? Int == 1)
        let eleventh = try #require(byDay["2026-10-11"])
        #expect(eleventh["unknown"] as? [String] == ["bed", "magnesium", "zone2"] && eleventh["missed"] == nil && eleventh["keptShare"] == nil,
                "a past day with no check is unknown, not missed")
        #expect(byDay["2026-10-16"]?["pending"] as? [String] == ["bed", "magnesium", "zone2"], "today can still be kept")
        #expect(byDay["2026-10-14"]?["version"] as? Int == 2 && byDay["2026-10-13"]?["version"] as? Int == 1, "each day uses the version in force")
        #expect(json["keptRules"] as? Int == 2 && json["decidedRules"] as? Int == 3 && json["keptShare"] as? Double == 0.67)
    }

    @Test func anExperimentWithoutABaselineShowsItsDesignAndNoResult() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let routine = try makeProtocol(rig)
        let start = try ExperimentStart(protocolID: routine.id, title: "Magnesium glycinate", interventionName: "magnesium", ruleKey: "magnesium",
                                        design: .alternatingDays, washout: 0, minimumNightsPerArm: 3, plannedNights: 14, outcome: .deepSleep,
                                        startDay: DayIdentity(routineDayKey: "2026-10-13")!, timeZoneIdentifier: AgentFixtures.zone.identifier,
                                        createdAt: tenth)
        let experiments = ExperimentStore(database: rig.database)
        try experiments.start(start)
        try experiments.recordNight(experimentID: start.id, day: DayIdentity(routineDayKey: "2026-10-13")!, adherence: .kept, outcomeValue: 62, at: AgentFixtures.now)

        let json = try object(await run(rig, AgentToolName.getExperiments))
        let row = try #require((json["experiments"] as? [[String: Any]])?.first)
        #expect(row["title"] as? String == "Magnesium glycinate" && row["running"] as? Bool == true && row["plannedNights"] as? Int == 14)
        #expect((row["design"] as? [String: Any])?["kind"] as? String == "alternating")
        #expect((row["outcome"] as? [String: Any])?["metric"] as? String == "deepSleepMinutes")
        let result = try #require(row["result"] as? [String: Any])
        #expect(result["state"] as? String == "cannotReport", "no nights before day 1, so no spread and no result")
        #expect(result["label"] == nil && result["difference"] == nil && result["likelyRange"] == nil)
        #expect(rig.source.flag("experimentResults") == true)
    }

    @Test func anExperimentResultIsLeftOutWhenBandMetricsIsOff() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let routine = try makeProtocol(rig)
        try ExperimentStore(database: rig.database).start(try ExperimentStart(
            protocolID: routine.id, title: "Magnesium", interventionName: "magnesium", ruleKey: "magnesium", design: .blocks(length: 7), washout: 1,
            minimumNightsPerArm: 5, plannedNights: 28, outcome: .hrv, startDay: DayIdentity(routineDayKey: "2026-10-13")!,
            timeZoneIdentifier: AgentFixtures.zone.identifier, createdAt: tenth))
        suite.set(.metrics, false)
        let json = try object(await run(rig, AgentToolName.getExperiments))
        let row = try #require((json["experiments"] as? [[String: Any]])?.first)
        #expect(row["result"] == nil && row["title"] as? String == "Magnesium")
        #expect(json["resultsWithheld"] != nil)
    }

    @Test func outcomeMetricsMapToTheirHistorySeries() {
        #expect(LooprLongevityAgentReader.historyKey(forOutcome: ExperimentMetric.deepSleep.key) == .deepSleep)
        #expect(LooprLongevityAgentReader.historyKey(forOutcome: ExperimentMetric.sleepHeartRate.key) == .sleepingHeartRate)
        #expect(LooprLongevityAgentReader.historyKey(forOutcome: ExperimentMetric.hrv.key) == .rmssd)
        #expect(LooprLongevityAgentReader.historyKey(forOutcome: ExperimentMetric.timeToFallAsleep.key) == nil, "no series, so no baseline and no result")
    }

    // MARK: Supplements

    @Test func supplementsNeverIncludeThePrescriberOrAnyNote() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let store = SupplementStore(database: rig.database)
        let d3 = try SupplementItem(name: "D3", dose: DoseAmount(amount: 2_000, unit: .iu), form: .capsule, schedule: .both, startDay: "2026-01-01", createdAt: tenth)
        let pill = try MedicationItem(name: "Ramipril", dose: DoseAmount(amount: 5, unit: .mg), prescriber: "Dr. Weber", schedule: .morning,
                                      notes: "private item note", startDay: "2026-01-01", createdAt: tenth)
        try store.save(d3); try store.save(pill)
        try store.record(.taken, itemID: d3.id, day: "2026-10-15", slot: .morning, at: AgentFixtures.now, note: "private tick note")
        try store.record(.skipped, itemID: d3.id, day: "2026-10-15", slot: .evening, at: AgentFixtures.now)
        try store.record(.taken, itemID: pill.id, day: "2026-10-15", slot: .morning, at: AgentFixtures.now, note: "tick note on a pill")

        let outcome = await run(rig, AgentToolName.getSupplements, ["from": "2026-10-15", "to": "2026-10-16"])
        let json = try object(outcome)
        for secret in ["Dr. Weber", "private item note", "private tick note", "tick note on a pill"] {
            #expect(!outcome.content.contains(secret), "\(secret) reached the model")
        }
        let everyDose = ((json["supplements"] as? [[String: Any]]) ?? []).flatMap { ($0["doses"] as? [[String: Any]]) ?? [] }
            + ((json["medication"] as? [[String: Any]]) ?? []).flatMap { ($0["doses"] as? [[String: Any]]) ?? [] }
        #expect(everyDose.count == 6, "two days of D3 morning and evening, two of Ramipril")
        for dose in everyDose { #expect(Set(dose.keys).isSubset(of: ["name", "dose", "slot", "status", "at"]), "\(dose.keys)") }
        let sent = try #require((json["supplements"] as? [[String: Any]])?.first?["doses"] as? [[String: Any]])
        #expect(sent.map { $0["status"] as? String } == ["taken", "skipped"] && sent[0]["dose"] as? String == "2000 IU")
        let pills = try #require((json["medication"] as? [[String: Any]])?.last?["doses"] as? [[String: Any]])
        #expect(pills.first?["status"] as? String == "notRecorded", "16 Oct was not recorded, so it is unknown")
    }

    // MARK: Blood tests

    @Test func labsSendWhatTheLabPrintedAndNoReportNote() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        let store = LabStore(database: rig.database)
        let report = LabReport(collectedAt: tenth, timeZoneIdentifier: AgentFixtures.zone.identifier, labName: "Labor Berlin", fasting: true,
                               source: .typed, createdAt: tenth, note: "private report note")
        let apob = LabValue(reportID: report.id, subject: .marker(.apoB), value: dec("78"), unit: "mg/dL",
                            referenceRange: LabReferenceRange(low: dec("40"), high: dec("90")), source: .typed)
        let crp = LabValue(reportID: report.id, subject: .marker(.crp), assay: "hs-CRP", value: dec("0.6"), printedValue: "0.60", unit: "mg/L",
                           referenceRange: LabReferenceRange(text: "<5.0"), flagText: "H", source: .typed)
        let other = LabValue(reportID: report.id, subject: .other(name: "Selenium"), value: dec("1.2"), unit: nil, source: .typed)
        try store.saveReport(report, values: [apob, crp, other])
        let older = LabReport(collectedAt: AgentFixtures.now.addingTimeInterval(-200 * 86_400), timeZoneIdentifier: AgentFixtures.zone.identifier,
                              source: .typed, createdAt: tenth)
        try store.saveReport(older, values: [LabValue(reportID: older.id, subject: .marker(.glucose), value: dec("5.1"), unit: "mmol/L", source: .typed)])
        try store.saveClockResult(LabClockResult(kind: .dunedinPACE, value: dec("0.92"), labName: "TruDiagnostic", collectedAt: tenth,
                                                 timeZoneIdentifier: AgentFixtures.zone.identifier, createdAt: tenth, note: "private clock note"))

        let outcome = await run(rig, AgentToolName.getLabs, ["from": "2026-10-01", "to": "2026-10-16"])
        let json = try object(outcome)
        #expect(!outcome.content.contains("private report note") && !outcome.content.contains("private clock note"))
        let sentReport = try #require((json["reports"] as? [[String: Any]])?.first)
        #expect((json["reports"] as? [[String: Any]])?.count == 1 && sentReport["lab"] as? String == "Labor Berlin" && sentReport["day"] as? String == "2026-10-10")
        let values = try #require(sentReport["values"] as? [[String: Any]])
        #expect(values.map { $0["value"] as? String } == ["78", "0.60", "1.2"], "the printed digits, in the order saved")
        #expect(values[0]["rangeMin"] as? String == "40" && values[0]["rangeMax"] as? String == "90" && values[0]["flag"] == nil && values[0]["marker"] as? String == "apob")
        #expect(values[1]["flag"] as? String == "H" && values[1]["rangeText"] as? String == "<5.0" && values[1]["assay"] as? String == "hs-CRP")
        #expect(values[2]["name"] as? String == "Selenium" && values[2]["unit"] == nil && values[2]["rangeMin"] == nil && values[2]["flag"] == nil,
                "Loopr fills in no unit, range or flag the lab did not print")
        #expect((json["clockResults"] as? [[String: Any]])?.first?["clock"] as? String == "DunedinPACE")
        #expect((json["otherReportDays"] as? [String])?.count == 1, "the older report is named by day so the model can ask for it")
        for key in ["normal", "abnormal", "optimal"] { #expect(!outcome.content.lowercased().contains(key), "\(key)") }
    }

    // MARK: Capacity

    @Test func capacityReadsStoredResultsGoalsAndWeeksWithTargetsFromTheProtocol() async throws {
        let rig = try makeRig(); defer { rig.cleanup() }
        try makeProtocol(rig)
        let store = CapacityStore(database: rig.database)
        try store.save(CapacityResult(kind: .grip, value: 41.5, side: .left, recordedAt: AgentFixtures.now.addingTimeInterval(-4 * 86_400),
                                      timeZoneIdentifier: AgentFixtures.zone.identifier))
        try store.save(CapacityResult(kind: .deadHang, value: 48, recordedAt: AgentFixtures.now.addingTimeInterval(-40 * 86_400),
                                      timeZoneIdentifier: AgentFixtures.zone.identifier))
        try store.save(CapacityGoal(kind: .grip, targetValue: 30, setAt: tenth))

        let json = try object(await run(rig, AgentToolName.getCapacity, ["from": "2026-10-10", "to": "2026-10-16"]))
        let results = try #require(json["results"] as? [[String: Any]])
        #expect(results.map { $0["test"] as? String } == ["grip"], "the dead hang from September is outside the range")
        #expect(results[0]["side"] as? String == "left" && results[0]["day"] as? String == "2026-10-12" && results[0]["unit"] as? String == "kg")
        #expect((json["goals"] as? [[String: Any]])?.first?["targetAtAge"] as? Int == 85)
        let weeks = try #require(json["weeklyDose"] as? [[String: Any]])
        #expect(weeks.map { $0["week"] as? String } == ["2026-W41", "2026-W42"])
        #expect(weeks[1]["zone2Target"] as? Double == 150, "the target comes from the Protocol rule")
        #expect(weeks[1]["zone2Minutes"] == nil, "no band data is unknown, not zero")

        suite.set(.journalAnswers, false)
        let without = try object(await run(rig, AgentToolName.getCapacity, ["from": "2026-10-10", "to": "2026-10-16"]))
        #expect((without["weeklyDose"] as? [[String: Any]])?.last?["zone2Target"] == nil, "no Protocol targets while Journal answers is off")
        #expect((without["results"] as? [[String: Any]])?.count == 1, "capacity results are Training and still read")
    }
}
