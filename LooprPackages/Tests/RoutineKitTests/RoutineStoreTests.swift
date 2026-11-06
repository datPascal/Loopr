import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

private final class RoutineTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutineKitTests-\(UUID().uuidString)")
    let database: StorageDatabase
    var store: RoutineStore { RoutineStore(database: database) }
    init() throws { database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "routine-tests") }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }

    func payload(_ number: Int, of id: ProtocolID) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM routine_version WHERE protocol_id = ? AND version = ?",
                              arguments: [id.rawValue.uuidString, number])
        }
    }
}

private let created = Date(timeIntervalSince1970: 1_700_000_000)
private let later = Date(timeIntervalSince1970: 1_700_086_400)
private let latest = Date(timeIntervalSince1970: 1_700_172_800)
private let day1 = DayIdentity(year: 2023, month: 11, day: 14)
private let day2 = DayIdentity(year: 2023, month: 11, day: 15)
private let day3 = DayIdentity(year: 2023, month: 11, day: 16)

private let protein: RuleKey = "protein"
private let zone2: RuleKey = "zone2"
private let lightsOut: RuleKey = "lights-out"
private let magnesium: RuleKey = "magnesium"

private func rules() -> [ProtocolRule] {
    [
        ProtocolRule(key: lightsOut, title: "Lights out", group: .sleep,
                     target: RuleTarget(kind: .atMost, metric: "bedtime", value: 1_365, unit: "min"),
                     timeOfDayMinutes: 1_305, source: .band, isEvening: true, rebuttal: "Tomorrow starts tonight."),
        ProtocolRule(key: protein, title: "Protein", group: .food,
                     target: RuleTarget(kind: .atLeast, metric: "protein", value: 130, unit: "g"), source: .food),
        ProtocolRule(key: zone2, title: "Zone 2", group: .fitness,
                     target: RuleTarget(kind: .atLeast, metric: "zone2Minutes", value: 45, unit: "min"), source: .fitness),
        ProtocolRule(key: magnesium, title: "Magnesium", group: .supplements, timeOfDayMinutes: 1_290, source: .manual)
    ]
}

private func sleepFirst(id: ProtocolID = ProtocolID()) -> RoutineProtocol {
    RoutineProtocol(id: id, name: "Sleep first", author: "Pascal",
                    lineage: ProtocolLineage(forkedFromName: "sleep-first", forkedFromVersion: 3), createdAt: created)
}

private func check(_ key: RuleKey, _ day: DayIdentity, version: Int = 1, _ state: CheckState,
                   source: CheckSource, value: Double? = nil, at date: Date = created) throws -> RuleCheck {
    try RuleCheck(ruleKey: key, day: day, version: version, state: state, source: source,
                  measuredValue: value, recordedAt: date)
}

struct RoutineStoreTests {
    @Test func createdProtocolReadsBackWithVersionOneAndSurvivesRestart() throws {
        let context = try RoutineTestDatabase()
        let routineProtocol = sleepFirst()
        let first = try context.store.createProtocol(routineProtocol, rules: rules(), note: "Start here")
        #expect(first.number == 1)
        #expect(first.createdAt == created)
        try context.database.databasePool.close()

        let reopened = try StorageDatabase(path: context.database.path, applicationVersion: "routine-tests")
        defer { try? reopened.databasePool.close() }
        let store = RoutineStore(database: reopened)
        #expect(try store.routineProtocol(id: routineProtocol.id) == routineProtocol)
        #expect(try store.version(protocolID: routineProtocol.id, number: 1) == first)
        #expect(try store.versions(protocolID: routineProtocol.id) == [first])
        let active = try #require(try store.activeProtocol())
        #expect(active.routineProtocol.lineage == ProtocolLineage(forkedFromName: "sleep-first", forkedFromVersion: 3))
        #expect(active.routineProtocol.author == "Pascal")
        #expect(active.latestVersion == first)
        #expect(active.latestVersion.rules.map(\.key) == [lightsOut, protein, zone2, magnesium])
        #expect(active.latestVersion.rules[0].isEvening && active.latestVersion.rules[0].rebuttal == "Tomorrow starts tonight.")
        #expect(active.latestVersion.rules[3].target == .done && active.latestVersion.rules[3].timeOfDayMinutes == 1_290)
        #expect(try store.version(protocolID: routineProtocol.id, number: 2) == nil)
    }

    @Test func noProtocolMeansNoActiveProtocol() throws {
        let context = try RoutineTestDatabase()
        #expect(try context.store.activeProtocol() == nil)
        #expect(try context.store.protocols().isEmpty)
    }

    @Test func versionBumpNumbersFromOneAndKeepsEarlierVersionsByteIdentical() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        let first = try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        let firstBytes = try #require(try context.payload(1, of: id))

        var changed = rules()
        changed[1] = ProtocolRule(key: protein, title: "Protein, every day", group: .food,
                                  target: RuleTarget(kind: .atLeast, metric: "protein", value: 140, unit: "g"), source: .food)
        changed.removeLast()
        let second = try context.store.saveVersion(protocolID: id, rules: changed, note: "More protein", at: later)
        let third = try context.store.saveVersion(protocolID: id, rules: rules(), at: latest)

        let numbers: [Int] = [first.number, second.number, third.number]
        #expect(numbers == [1, 2, 3])
        #expect(second.note == "More protein" && second.createdAt == later)
        #expect(try context.payload(1, of: id) == firstBytes)
        #expect(try context.store.version(protocolID: id, number: 1) == first)
        #expect(try context.store.versions(protocolID: id) == [first, second, third])
        #expect(try context.store.latestVersion(protocolID: id) == third)
        #expect(try context.store.activeProtocol()?.latestVersion == third)
        #expect(second.rules.count == 3 && first.rules.count == 4)
    }

    @Test func aSavedVersionRejectsAnUpdate() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        let before = try context.payload(1, of: id)
        #expect(throws: (any Error).self) {
            try context.database.write { db in
                try db.execute(sql: "UPDATE routine_version SET payload = X'7B7D' WHERE protocol_id = ?",
                               arguments: [id.rawValue.uuidString])
            }
        }
        #expect(try context.payload(1, of: id) == before)
    }

    @Test func savingToAnUnknownProtocolFails() throws {
        let context = try RoutineTestDatabase()
        #expect(throws: RoutineError.missingProtocol) {
            try context.store.saveVersion(protocolID: ProtocolID(), rules: rules(), at: later)
        }
    }

    @Test func invalidRulesAndProtocolsAreRejectedBeforeAnythingIsWritten() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        func create(_ rules: [ProtocolRule]) throws { try context.store.createProtocol(sleepFirst(id: id), rules: rules) }

        #expect(throws: RoutineError.invalidRule("blank")) { try create([ProtocolRule(key: "blank", title: "  ")]) }
        #expect(throws: RoutineError.invalidRule("late")) {
            try create([ProtocolRule(key: "late", title: "Late", timeOfDayMinutes: 1_440)])
        }
        #expect(throws: RoutineError.invalidRule("early")) {
            try create([ProtocolRule(key: "early", title: "Early", timeOfDayMinutes: -1)])
        }
        #expect(throws: RoutineError.invalidRule("novalue")) {
            try create([ProtocolRule(key: "novalue", title: "No value", target: RuleTarget(kind: .atLeast, metric: "protein"))])
        }
        #expect(throws: RoutineError.invalidRule("nan")) {
            try create([ProtocolRule(key: "nan", title: "NaN", target: RuleTarget(kind: .atMost, value: .nan))])
        }
        #expect(throws: RoutineError.duplicateRuleKey) {
            try create([ProtocolRule(key: "same", title: "One"), ProtocolRule(key: "same", title: "Two")])
        }
        #expect(throws: RoutineError.invalidProtocol) {
            try context.store.createProtocol(RoutineProtocol(name: " ", createdAt: created), rules: [])
        }
        #expect(try context.store.protocols().isEmpty)
        #expect(try context.database.tableRowCounts()["routine_version"] == 0)
    }

    @Test func aProtocolCanStartEmpty() throws {
        let context = try RoutineTestDatabase()
        let first = try context.store.createProtocol(RoutineProtocol(name: "Start empty", createdAt: created), rules: [])
        #expect(first.rules.isEmpty && first.number == 1)
    }

    @Test func oneProtocolIsActiveAtATime() throws {
        let context = try RoutineTestDatabase()
        let a = sleepFirst()
        let b = RoutineProtocol(name: "Everything at once", createdAt: later)
        try context.store.createProtocol(a, rules: rules())
        try context.store.createProtocol(b, rules: [ProtocolRule(key: "walk", title: "Walk")])
        #expect(try context.store.activeProtocol()?.routineProtocol.id == b.id)
        #expect(try context.store.protocols().map(\.id) == [a.id, b.id])

        try context.store.setActive(protocolID: a.id)
        #expect(try context.store.activeProtocol()?.routineProtocol.id == a.id)
        try context.store.createProtocol(RoutineProtocol(name: "Parked", createdAt: latest), rules: [], activate: false)
        #expect(try context.store.activeProtocol()?.routineProtocol.id == a.id)
        #expect(throws: RoutineError.missingProtocol) { try context.store.setActive(protocolID: ProtocolID()) }
    }

    @Test func aRulesHistoryFollowsItsKeyAcrossVersions() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        try context.store.recordCheck(check(protein, day1, .kept, source: .food, value: 132, at: created), protocolID: id)
        try context.store.recordCheck(check(zone2, day1, .missed, source: .fitness, value: 20, at: created), protocolID: id)

        var changed = rules()
        changed[1] = ProtocolRule(key: protein, title: "Protein, every day", group: .food,
                                  target: RuleTarget(kind: .atLeast, metric: "protein", value: 140, unit: "g"), source: .food)
        try context.store.saveVersion(protocolID: id, rules: changed, at: later)
        try context.store.recordCheck(check(protein, day2, version: 2, .missed, source: .food, value: 90, at: later), protocolID: id)
        try context.store.recordCheck(check(protein, day3, version: 2, .kept, source: .food, value: 141, at: latest), protocolID: id)

        let history = try context.store.history(protocolID: id, ruleKey: protein)
        #expect(history.map(\.day) == [day1, day2, day3])
        #expect(history.map(\.version) == [1, 2, 2])
        #expect(history.map(\.state) == [.kept, .missed, .kept])
        #expect(history.map(\.measuredValue) == [132, 90, 141])
        #expect(try context.store.history(protocolID: id, ruleKey: protein, from: day2, through: day2).map(\.day) == [day2])
        #expect(try context.store.history(protocolID: id, ruleKey: protein, from: day2).map(\.day) == [day2, day3])
        #expect(try context.store.history(protocolID: id, ruleKey: zone2).map(\.day) == [day1])
        #expect(try context.store.checks(protocolID: id, day: day1).map(\.ruleKey) == [protein, zone2])
        #expect(try context.store.checks(protocolID: id, day: day2).map(\.ruleKey) == [protein])
    }

    @Test func recordingAgainReplacesAnAutomaticCheckForTheSameDay() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        try context.store.recordCheck(check(protein, day1, .pending, source: .food, value: 60), protocolID: id)
        try context.store.recordCheck(check(protein, day1, .kept, source: .food, value: 135, at: later), protocolID: id)
        let stored = try context.store.history(protocolID: id, ruleKey: protein)
        #expect(stored.count == 1 && stored[0].state == .kept && stored[0].measuredValue == 135 && stored[0].recordedAt == later)
    }

    @Test func aPersonsOverrideWinsAndSurvivesAutomaticRechecks() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        try context.store.recordCheck(check(protein, day1, .missed, source: .food, value: 110), protocolID: id)

        let overridden = try context.store.overrideCheck(protocolID: id, ruleKey: protein, day: day1, state: .kept, at: later)
        #expect(overridden.state == .kept && overridden.source == .manual && overridden.overriddenByPerson)
        #expect(overridden.measuredValue == 110 && overridden.version == 1 && overridden.recordedAt == later)

        let ignored = try context.store.recordCheck(check(protein, day1, .missed, source: .food, value: 112, at: latest), protocolID: id)
        #expect(ignored == overridden)
        #expect(try context.store.check(protocolID: id, ruleKey: protein, day: day1) == overridden)

        let again = try context.store.overrideCheck(protocolID: id, ruleKey: protein, day: day1, state: .missed, at: latest)
        #expect(again.state == .missed && again.overriddenByPerson)
    }

    @Test func overridingADayWithNoCheckUsesTheNewestVersion() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        try context.store.saveVersion(protocolID: id, rules: rules(), at: later)
        let made = try context.store.overrideCheck(protocolID: id, ruleKey: magnesium, day: day1, state: .kept, at: later)
        #expect(made.version == 2 && made.measuredValue == nil && made.source == .manual)
        #expect(throws: RoutineError.unknownRule("nothing")) {
            try context.store.overrideCheck(protocolID: id, ruleKey: "nothing", day: day1, state: .kept, at: later)
        }
        #expect(throws: RoutineError.invalidOverride) {
            try context.store.overrideCheck(protocolID: id, ruleKey: magnesium, day: day2, state: .unknown, at: later)
        }
        #expect(throws: RoutineError.invalidOverride) {
            try context.store.overrideCheck(protocolID: id, ruleKey: magnesium, day: day2, state: .pending, at: later)
        }
    }

    @Test func unknownStaysUnknownAndNeverBecomesMissedOrZero() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        try context.store.recordCheck(check(lightsOut, day1, .unknown, source: .band), protocolID: id)

        let stored = try #require(try context.store.check(protocolID: id, ruleKey: lightsOut, day: day1))
        #expect(stored.state == .unknown && stored.measuredValue == nil && !stored.overriddenByPerson)
        #expect(try context.store.history(protocolID: id, ruleKey: lightsOut).filter { $0.state == .missed }.isEmpty)
        // A rule nobody checked has no row at all, which is also not a miss.
        #expect(try context.store.check(protocolID: id, ruleKey: zone2, day: day1) == nil)
        #expect(try context.store.checks(protocolID: id, day: day1).map(\.state) == [.unknown])

        #expect(throws: RoutineError.invalidCheck) { try check(lightsOut, day1, .unknown, source: .band, value: 0) }
        #expect(throws: RoutineError.invalidCheck) { try check(protein, day1, .kept, source: .food, value: .infinity) }
        #expect(throws: (any Error).self) {
            try context.database.write { db in
                try db.execute(sql: """
                    INSERT INTO routine_check VALUES (?, 'x', '2023-11-14', 1, 'unknown', 'band', 0, 0, 1, NULL)
                    """, arguments: [id.rawValue.uuidString])
            }
        }
    }

    @Test func pendingMayCarryAPartialValue() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        let partial = try context.store.recordCheck(check(protein, day1, .pending, source: .food, value: 64), protocolID: id)
        #expect(partial.measuredValue == 64 && partial.state == .pending)
    }

    @Test func checksNeedAnExistingProtocolVersionAndRule() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        #expect(throws: RoutineError.unknownRule("nothing")) {
            try context.store.recordCheck(check("nothing", day1, .kept, source: .manual), protocolID: id)
        }
        #expect(throws: RoutineError.missingVersion) {
            try context.store.recordCheck(check(protein, day1, version: 2, .kept, source: .food), protocolID: id)
        }
        #expect(throws: RoutineError.missingProtocol) {
            try context.store.recordCheck(check(protein, day1, .kept, source: .food), protocolID: ProtocolID())
        }
        #expect(try context.database.tableRowCounts()["routine_check"] == 0)
    }

    @Test func deletingAProtocolRemovesItsVersionsAndChecksAndLeavesOthers() throws {
        let context = try RoutineTestDatabase()
        let doomed = ProtocolID()
        let kept = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: kept), rules: rules(), activate: false)
        try context.store.createProtocol(sleepFirst(id: doomed), rules: rules())
        try context.store.saveVersion(protocolID: doomed, rules: rules(), at: later)
        try context.store.recordCheck(check(protein, day1, .kept, source: .food, value: 130), protocolID: doomed)
        try context.store.recordCheck(check(protein, day1, .missed, source: .food, value: 10), protocolID: kept)
        #expect(try context.database.tableRowCounts()["routine_version"] == 3)

        #expect(try context.store.deleteProtocol(id: doomed))
        #expect(try context.store.routineProtocol(id: doomed) == nil)
        #expect(try context.store.versions(protocolID: doomed).isEmpty)
        #expect(try context.store.history(protocolID: doomed, ruleKey: protein).isEmpty)
        #expect(try context.store.activeProtocol() == nil)
        let counts = try context.database.tableRowCounts()
        #expect(counts["routine_protocol"] == 1 && counts["routine_version"] == 1 && counts["routine_check"] == 1)
        #expect(try context.store.history(protocolID: kept, ruleKey: protein).count == 1)
        #expect(try context.store.deleteProtocol(id: doomed) == false)
    }

    @Test func deletingAllAccountDataEmptiesTheRoutineTables() throws {
        let context = try RoutineTestDatabase()
        let id = ProtocolID()
        try context.store.createProtocol(sleepFirst(id: id), rules: rules())
        try context.store.recordCheck(check(protein, day1, .kept, source: .food, value: 130), protocolID: id)
        try context.database.deleteAllAccountData()
        let counts = try context.database.tableRowCounts()
        for table in RoutineStorageSchema.tableNames { #expect(counts[table] == 0, "\(table)") }
        #expect(try context.store.activeProtocol() == nil)
    }

    @Test func versionPayloadsWithoutOptionalFieldsStillDecode() throws {
        let json = """
        {"protocolID":"\(UUID().uuidString)","number":1,"createdAt":0,
         "rules":[{"key":"walk","title":"Walk","group":"fitness","target":{"kind":"done"},"source":"manual"}]}
        """
        let version = try JSONDecoder().decode(ProtocolVersion.self, from: Data(json.utf8))
        #expect(version.rules[0].isEvening == false && version.rules[0].rebuttal == nil && version.rules[0].timeOfDayMinutes == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ProtocolVersion.self, from: Data(json.replacingOccurrences(of: "\"number\":1", with: "\"number\":0").utf8))
        }
    }

    @Test func dayKeysRoundTripAndRejectImpossibleDays() {
        #expect(day1.routineDayKey == "2023-11-14")
        #expect(DayIdentity(routineDayKey: "2023-11-14") == day1)
        #expect(DayIdentity(routineDayKey: "2023-02-30") == nil)
        #expect(DayIdentity(routineDayKey: "2023-2-3") == nil)
        #expect(DayIdentity(year: 2023, month: 13, day: 1).routineDayKey == nil)
    }
}
