import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

// ICP R1-HAB-02, R1-VET-08, R1-VET-23: chosen weekdays and "N times a week", the one due-day function, the off day that
// makes no check, the week's progress, and payloads and files from before the new fields.

private final class CadenceTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RuleCadenceTests-\(UUID().uuidString)")
    let database: StorageDatabase
    let store: RoutineStore
    init() throws {
        database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "rule-cadence-tests")
        store = RoutineStore(database: database)
    }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
}

/// Mon 16 Nov 2026 to Sun 22 Nov 2026.
private func day(_ value: Int) -> DayIdentity { DayIdentity(year: 2026, month: 11, day: value) }
private let week = (16...22).map(day)
private let created = Date(timeIntervalSince1970: 1_790_000_000)
private let zone = TimeZone(identifier: "Europe/Berlin")!

private let gym = ProtocolRule(key: "gym", title: "Gym", group: .fitness, source: .manual, cadence: .on([.monday, .wednesday, .friday]))
private let zone2Weekdays = ProtocolRule(key: "zone2", title: "Zone 2, 45 min", group: .fitness,
                                         target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 45, unit: "min"),
                                         source: .band, cadence: .on([.tuesday, .thursday]))
private let swim = ProtocolRule(key: "swim", title: "Swim", group: .fitness, cadence: .timesAWeek(3))
private let zone2Week = ProtocolRule(key: "zone2-week", title: "Zone 2, 150 min a week", group: .fitness,
                                     target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 150, unit: "min"),
                                     source: .band, cadence: RuleCadence(unit: .week))
private let panel = ProtocolRule(key: "panel", title: "Blood panel", group: .tests, cadence: RuleCadence(unit: .month, every: 3))

private func kept(_ key: RuleKey, _ day: DayIdentity, _ state: CheckState = .kept) throws -> RuleCheck {
    try RuleCheck(ruleKey: key, day: day, version: 1, state: state, source: .manual, recordedAt: created)
}

struct RuleCadenceTests {
    // MARK: Due days

    @Test func weekdaysFollowTheCalendarInEveryTimeZone() {
        #expect(RuleWeekday(day: day(16)) == .monday)
        #expect(RuleWeekday(day: day(22)) == .sunday)
        #expect(RuleWeekday(day: DayIdentity(year: 2024, month: 2, day: 29)) == .thursday, "a leap day")
        #expect(RuleWeekday(day: DayIdentity(year: 2026, month: 2, day: 30)) == nil, "a day that does not exist")
        #expect(RuleWeekday(calendarWeekday: 1) == .sunday && RuleWeekday(calendarWeekday: 2) == .monday)
        #expect(RuleWeekday.allCases.map(\.isoNumber) == Array(1...7))
    }

    @Test func aRuleOnChosenDaysIsDueOnThoseDaysOnly() {
        #expect(week.map(gym.isDue(on:)) == [true, false, true, false, true, false, false])
        #expect(week.allSatisfy(swim.isDue(on:)), "times a week can be done on any day")
        #expect(week.allSatisfy(panel.isDue(on:)))
        #expect(week.allSatisfy(ProtocolRule(key: "walk", title: "Walk").isDue(on:)), "no cadence is every day")
        #expect(gym.cadence?.isDaily == true && gym.cadence?.isEveryDay == false)
    }

    @Test func timesAWeekStopsBeingDueOnceTheCountIsReached() {
        #expect(swim.isDue(on: day(18), keptThisWeek: 2))
        #expect(!swim.isDue(on: day(18), keptThisWeek: 3))
        #expect(!gym.isDue(on: day(17), keptThisWeek: 0), "an off day stays off")
        #expect(gym.isDue(on: day(16), keptThisWeek: 5), "a rule on chosen days has no weekly count")
    }

    @Test func allSevenDaysOrOneTimeAWeekReadAsThePlainCadences() {
        #expect(RuleCadence.on(Set(RuleWeekday.allCases)).isEveryDay)
        #expect(RuleCadence.on([]).isEveryDay)
        #expect(RuleCadence.on([.friday, .monday]).days == [.monday, .friday], "Monday first")
        #expect(RuleCadence.timesAWeek(1) == RuleCadence(unit: .week))
        #expect(RuleCadence.timesAWeek(7).isEveryDay)
        #expect(RuleCadence.timesAWeek(4).timesPerWeek == 4)
        #expect(ProtocolRule(key: "a", title: "A", cadence: .on(Set(RuleWeekday.allCases))).normalized.cadence == nil)
    }

    // MARK: Payloads

    @Test func oldPayloadsDecodeUnchangedAndNewOnesRoundTrip() throws {
        let old = try JSONDecoder().decode(RuleCadence.self, from: Data(#"{"unit":"week","every":2}"#.utf8))
        #expect(old == RuleCadence(unit: .week, every: 2))
        #expect(old.days.isEmpty && old.timesPerWeek == nil)

        let plain = String(decoding: try JSONEncoder().encode(RuleCadence(unit: .month, every: 6)), as: UTF8.self)
        #expect(!plain.contains("days") && !plain.contains("timesPerWeek"), "a plain cadence keeps the old shape")

        for cadence in [RuleCadence.on([.monday, .wednesday, .friday]), .timesAWeek(3)] {
            #expect(try JSONDecoder().decode(RuleCadence.self, from: try JSONEncoder().encode(cadence)) == cadence)
        }
        let rule = #"{"key":"gym","title":"Gym","group":"fitness","target":{"kind":"done"},"source":"manual","cadence":{"unit":"day","every":1,"days":["fri","mon"]}}"#
        #expect(try JSONDecoder().decode(ProtocolRule.self, from: Data(rule.utf8)).cadence?.days == [.monday, .friday])
    }

    @Test func aVersionWithTheNewCadencesSurvivesTheStore() throws {
        let context = try CadenceTestDatabase()
        let mine = RoutineProtocol(name: "Mine", createdAt: created)
        try context.store.createProtocol(mine, rules: [gym, swim, panel])
        #expect(try context.store.latestVersion(protocolID: mine.id)?.rules == [gym, swim, panel])
    }

    // MARK: Files

    @Test func filesCarryDaysAndTimesAndReadThemBack() throws {
        let file = ProtocolFile(name: "Shifts", version: 1, createdAt: created, rules: [gym, swim, zone2Week])
        let encoded = try ProtocolFileCodec.encode(file)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains(#""days" : ["#) && text.contains(#""mon""#) && text.contains(#""times" : 3"#))
        let preview = try ProtocolFileCodec.validate(encoded)
        #expect(preview.file.rules == [gym, swim, zone2Week])
        #expect(preview.ignoredFields.isEmpty)
    }

    @Test func aFileWithDaysOrTimesInTheWrongPlaceIsRefused() throws {
        func file(_ cadence: String) -> Data {
            Data(#"{"format":"loopr-protocol","schemaVersion":1,"name":"A","version":1,"createdAt":"2026-11-01T08:00:00Z","rules":[{"key":"a","title":"A","group":"custom","source":"manual","target":{"kind":"done"},"cadence":\#(cadence)}]}"#.utf8)
        }
        #expect(try ProtocolFileCodec.validate(file(#"{"unit":"day","days":["tue","sat"]}"#)).file.rules[0].cadence == .on([.tuesday, .saturday]))
        #expect(try ProtocolFileCodec.validate(file(#"{"unit":"week","times":1}"#)).file.rules[0].cadence == RuleCadence(unit: .week))
        let everyDay = try ProtocolFileCodec.validate(file(#"{"unit":"day","days":["mon","tue","wed","thu","fri","sat","sun"]}"#))
        #expect(everyDay.file.rules[0].cadence?.isEveryDay == true, "all seven days are every day")
        for bad in [#"{"unit":"week","days":["mon"]}"#, #"{"unit":"day","every":2,"days":["mon"]}"#, #"{"unit":"day","days":["monday"]}"#,
                    #"{"unit":"day","days":[]}"#, #"{"unit":"day","days":["mon","mon"]}"#] {
            #expect(throws: ProtocolFileError.invalidValue("rules[0].cadence.days")) { try ProtocolFileCodec.validate(file(bad)) }
        }
        for bad in [#"{"unit":"day","times":3}"#, #"{"unit":"week","every":2,"times":3}"#, #"{"unit":"week","times":8}"#] {
            #expect(throws: ProtocolFileError.invalidValue("rules[0].cadence.times")) { try ProtocolFileCodec.validate(file(bad)) }
        }
    }

    // MARK: Day evaluation

    @Test func anOffDayMakesNoCheckAndADueDayIsScoredDaily() throws {
        let context = try CadenceTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(RoutineProtocol(id: id, name: "Shifts", createdAt: created), rules: [gym, zone2Weekdays])
        let sources = RoutineSourceSnapshots(band: RoutineSourceSnapshot(source: .band, readings: [.zone2Minutes: .measured(50)]))
        let evaluation = RoutineDayEvaluation(store: context.store)

        let monday = try #require(RoutineDayClock(day: day(16), timeZone: zone))
        let onMonday = try #require(try evaluation.evaluate(day: day(16), now: monday.end, timeZone: zone, sources: sources))
        #expect(onMonday.checks.map(\.ruleKey) == ["gym"], "zone 2 is off on Monday")
        #expect(onMonday.summary.total == 1)

        let tuesday = try #require(RoutineDayClock(day: day(17), timeZone: zone))
        let onTuesday = try #require(try evaluation.evaluate(day: day(17), now: tuesday.end, timeZone: zone, sources: sources))
        #expect(onTuesday.checks.map(\.ruleKey) == ["zone2"], "the gym is off on Tuesday")
        #expect(onTuesday.checks[0].state == .kept, "a rule on chosen days is scored like a daily rule, not as a longer period")
        #expect(try context.store.checks(protocolID: id, day: day(17)).map(\.ruleKey) == ["zone2"])
    }

    // MARK: Progress

    @Test func timesAWeekCountsTheKeptDaysOfTheWeek() throws {
        let history = [try kept("swim", day(9)), try kept("swim", day(16)), try kept("swim", day(18)),
                       try kept("swim", day(19), .unknown)]
        let progress = RuleProgressReader.progress(for: swim, week: Array(week.prefix(4)), history: history, readings: [:])
        #expect(progress == .times(done: 2, target: 3), "last week's swim and an unknown day do not count")
        let weekly = ProtocolRule(key: "call", title: "Call mum", cadence: RuleCadence(unit: .week))
        #expect(RuleProgressReader.progress(for: weekly, week: week, history: [], readings: [:]) == .times(done: 0, target: 1))
        #expect(RuleProgressReader.progress(for: gym, week: week, history: [], readings: [:]) == nil, "a rule on chosen days is daily")
    }

    @Test func aWeeklySourceRuleAddsUpTheDaysWithAReading() {
        func band(_ minutes: Double?) -> RoutineSourceSnapshots {
            RoutineSourceSnapshots(band: RoutineSourceSnapshot(source: .band, readings: minutes.map { [.zone2Minutes: .measured($0)] } ?? [:]))
        }
        let readings = [day(16): band(40), day(17): band(nil), day(18): band(72)]
        #expect(RuleProgressReader.progress(for: zone2Week, week: Array(week.prefix(3)), history: [], readings: readings)
                == .amount(measured: 112, target: 150, unit: "min"))
        #expect(RuleProgressReader.progress(for: zone2Week, week: Array(week.prefix(3)), history: [], readings: [:])
                == .amount(measured: nil, target: 150, unit: "min"), "nothing measured is never zero")
        #expect(RuleProgressReader.needsReadings(zone2Week) && !RuleProgressReader.needsReadings(swim))
    }

    @Test func aLongerRuleSaysWhenItWasLastDoneAndWhenItIsDue() throws {
        let history = [try kept("panel", DayIdentity(year: 2026, month: 6, day: 2)),
                       try kept("panel", DayIdentity(year: 2026, month: 9, day: 12)),
                       try kept("panel", DayIdentity(year: 2026, month: 10, day: 1), .missed)]
        #expect(RuleProgressReader.progress(for: panel, week: week, history: history, readings: [:])
                == .due(lastDone: DayIdentity(year: 2026, month: 9, day: 12), next: DayIdentity(year: 2026, month: 12, day: 12)))
        #expect(RuleProgressReader.progress(for: panel, week: week, history: [], readings: [:]) == .due(lastDone: nil, next: nil))
        #expect(RuleProgressReader.next(after: DayIdentity(year: 2026, month: 8, day: 31), cadence: RuleCadence(unit: .month, every: 6))
                == DayIdentity(year: 2027, month: 2, day: 28), "the end of a shorter month")
    }
}
