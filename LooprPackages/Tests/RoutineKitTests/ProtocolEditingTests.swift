import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

/// LV-07.4: editing a protocol writes exactly one new immutable version, a rebuttal lives only on an evening rule and
/// never travels in a file, a template starts version 1 once, and a file the person uses becomes the next version with
/// its lineage while an invalid file changes nothing.
private final class EditingDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtocolEditingTests-\(UUID().uuidString)")
    let database: StorageDatabase
    let store: RoutineStore
    init() throws {
        database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "protocol-editing-tests")
        store = RoutineStore(database: database)
    }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
}

private let created = Date(timeIntervalSince1970: 1_790_000_000)

private let bed = ProtocolRule(key: "in-bed", title: "In bed by 22:30", group: .sleep,
                               target: RuleTarget(kind: .atMost, metric: "in_bed_time", value: 1_350, unit: "min"),
                               timeOfDayMinutes: 21 * 60 + 45, source: .band, isEvening: true)
private let screens = ProtocolRule(key: "screens-off", title: "Screens off by 21:45", group: .sleep, timeOfDayMinutes: 21 * 60 + 45,
                                   isEvening: true)
private let light = ProtocolRule(key: "light", title: "Morning light", group: .sleep, timeOfDayMinutes: 8 * 60)

struct ProtocolEditingTests {
    private func makeProtocol(_ context: EditingDatabase, rules: [ProtocolRule] = [bed, screens, light]) throws -> RoutineProtocol {
        let mine = RoutineProtocol(name: "Mine", author: "Sam", createdAt: created)
        try context.store.createProtocol(mine, rules: rules)
        return mine
    }

    @Test func anEditCreatesExactlyOneNewVersionAndEarlierVersionsStayUnchanged() throws {
        let context = try EditingDatabase()
        let mine = try makeProtocol(context)
        let first = try #require(try context.store.version(protocolID: mine.id, number: 1))
        let before = try context.database.tableRowCounts()

        let edited = [bed, screens.with(timeOfDayMinutes: .some(22 * 60), rebuttal: .some("Tomorrow starts tonight.")), light]
        let saved = try context.store.saveEdit(protocolID: mine.id, rules: edited, at: created.addingTimeInterval(60))

        #expect(saved.number == 2)
        #expect(try context.database.tableRowCounts()["routine_version"] == (before["routine_version"] ?? 0) + 1)
        #expect(try context.store.version(protocolID: mine.id, number: 1) == first, "version 1 reads as it was saved")
        #expect(saved.rule(for: "screens-off")?.timeOfDayMinutes == 22 * 60)
        #expect(saved.note == "Changed Screens off by 21:45: time and reason.")
        #expect(try context.store.activeProtocol()?.latestVersion == saved)
    }

    @Test func anEditWithNoChangeWritesNothing() throws {
        let context = try EditingDatabase()
        let mine = try makeProtocol(context)
        let before = try context.database.tableRowCounts()
        #expect(throws: ProtocolEditError.noChange) {
            try context.store.saveEdit(protocolID: mine.id, rules: [bed, screens, light], at: created.addingTimeInterval(60))
        }
        #expect(try context.database.tableRowCounts() == before)
    }

    @Test func addingAndRemovingARuleAreVersionsToo() throws {
        let context = try EditingDatabase()
        let mine = try makeProtocol(context)
        let stretch = ProtocolRule(key: "stretch", title: "Stretch")
        let added = try context.store.saveEdit(protocolID: mine.id, rules: [bed, screens, light, stretch], at: created.addingTimeInterval(10))
        #expect(added.number == 2 && added.note == "Added Stretch.")
        let removed = try context.store.saveEdit(protocolID: mine.id, rules: [bed, screens, stretch], at: created.addingTimeInterval(20))
        #expect(removed.number == 3 && removed.note == "Removed Morning light.")
        #expect(try context.store.versions(protocolID: mine.id).map(\.rules.count) == [3, 4, 3])
    }

    /// ICP R2-VET-07: "Why this change?" becomes the version's note; without one Loopr notes what changed, and the
    /// Versions row says what changed either way.
    @Test func theReasonAtSaveBecomesTheVersionsNote() throws {
        let context = try EditingDatabase()
        let mine = try makeProtocol(context)
        let stretch = ProtocolRule(key: "stretch", title: "Stretch")
        let moved = [bed, screens.with(timeOfDayMinutes: .some(21 * 60 + 30)), light, stretch]
        let saved = try context.store.saveEdit(protocolID: mine.id, rules: moved, reason: "  My GP asked for it. ",
                                               at: created.addingTimeInterval(60))
        #expect(saved.note == "My GP asked for it.")
        let changes = ProtocolVersionDiff.changes(from: [bed, screens, light], to: saved.rules)
        #expect(ProtocolVersionDiff.rowSummary(changes, locale: Locale(identifier: "en_GB")) == "Changed Screens off by 21:45: time to 21:30 \u{00B7} Added Stretch")
        #expect(!ProtocolVersionDiff.isAutomaticNote(saved.note, for: changes))

        let blank = try context.store.saveEdit(protocolID: mine.id, rules: [bed, screens, light], reason: "   ",
                                               at: created.addingTimeInterval(120))
        #expect(blank.note == "Changed Screens off by 21:45: time. Removed Stretch.", "a blank reason is no reason")
        #expect(ProtocolVersionDiff.isAutomaticNote(blank.note, for: ProtocolVersionDiff.changes(from: moved, to: blank.rules)))
        #expect(ProtocolVersionDiff.rowSummary([]) == nil)
        #expect(ProtocolVersionDiff.rowSummary([.changed(before: light, after: light.with(title: "Daylight"), fields: [.title])],
                                               locale: Locale(identifier: "en_GB")) == "Renamed Morning light to Daylight")

        #expect(throws: ProtocolEditError.reasonTooLong) {
            try context.store.saveEdit(protocolID: mine.id, rules: moved, reason: String(repeating: "a", count: 281),
                                       at: created.addingTimeInterval(180))
        }
    }

    @Test func aRebuttalIsStoredOnlyOnAnEveningRule() throws {
        let context = try EditingDatabase()
        let mine = try makeProtocol(context)
        let rules = [bed.with(rebuttal: .some("  Tomorrow starts tonight.  ")),
                     screens.with(rebuttal: .some("   ")),
                     light.with(rebuttal: .some("Not an evening rule"))]
        let saved = try context.store.saveEdit(protocolID: mine.id, rules: rules, at: created.addingTimeInterval(60))
        #expect(saved.rule(for: "in-bed")?.rebuttal == "Tomorrow starts tonight.", "trimmed and kept on an evening rule")
        #expect(saved.rule(for: "screens-off")?.rebuttal == nil, "a blank reason is no reason")
        #expect(saved.rule(for: "light")?.rebuttal == nil, "a morning rule never stores a rebuttal")

        #expect(throws: ProtocolEditError.rebuttalTooLong) {
            try context.store.saveEdit(protocolID: mine.id, rules: [bed.with(rebuttal: .some(String(repeating: "a", count: 281))), screens, light],
                                       at: created.addingTimeInterval(120))
        }
    }

    /// The source is kept trimmed, a blank one is dropped, a long one is refused, and a change to it is named in the
    /// version's note (ICP R2-NEW-07).
    @Test func evidenceIsTrimmedCappedAndNamedInTheNote() throws {
        let context = try EditingDatabase()
        let mine = try makeProtocol(context)
        let sourced = bed.with(evidence: .some("  A 2015 consensus says adults need 7 to 9 hours.  "))
        let saved = try context.store.saveEdit(protocolID: mine.id, rules: [sourced, screens.with(evidence: .some("   ")), light],
                                               at: created.addingTimeInterval(60))
        #expect(saved.rule(for: "in-bed")?.evidence == "A 2015 consensus says adults need 7 to 9 hours.")
        #expect(saved.rule(for: "screens-off")?.evidence == nil, "a blank source is no source")
        #expect(saved.note?.contains("where it comes from") == true, "\(saved.note ?? "")")
        #expect(throws: ProtocolEditError.evidenceTooLong) {
            try context.store.saveEdit(protocolID: mine.id,
                                       rules: [bed.with(evidence: .some(String(repeating: "a", count: ProtocolFile.maximumEvidenceLength + 1))), screens, light],
                                       at: created.addingTimeInterval(120))
        }
    }

    @Test func aSharedFileNeverCarriesTheRebuttal() throws {
        let context = try EditingDatabase()
        let mine = try makeProtocol(context, rules: [bed.with(rebuttal: .some("Tomorrow starts tonight.")), light])
        let text = try #require(String(data: try ProtocolFileCodec.encode(try context.store.exportFile(protocolID: mine.id)), encoding: .utf8))
        #expect(!text.contains("Tomorrow starts tonight.") && !text.contains("rebuttal"))
    }

    @Test func aTemplateInstallCreatesVersionOneOnce() throws {
        let context = try EditingDatabase()
        let first = try context.store.installTemplate(.sleepFirst, at: created)
        #expect(first.number == 1)
        let active = try #require(try context.store.activeProtocol())
        #expect(active.routineProtocol.name == "Sleep first")
        #expect(active.routineProtocol.lineage == ProtocolLineage(forkedFromName: "sleep-first", forkedFromVersion: 1))
        #expect(active.latestVersion.rules.map(\.key) == (try ProtocolTemplate.sleepFirst.load().file.rules.map(\.key)))

        let before = try context.database.tableRowCounts()
        #expect(throws: ProtocolEditError.protocolExists) { try context.store.installTemplate(.everythingAtOnce, at: created.addingTimeInterval(5)) }
        #expect(try context.database.tableRowCounts() == before, "a second pick writes nothing")
        #expect(try context.store.protocols().count == 1)
    }

    @Test func startEmptyIsMyProtocolWithNoRules() throws {
        let context = try EditingDatabase()
        let first = try context.store.installTemplate(.startEmpty, at: created)
        let active = try #require(try context.store.activeProtocol())
        #expect(first.rules.isEmpty && active.routineProtocol.name == "My protocol" && active.routineProtocol.lineage == nil)
    }

    @Test func usingAValidFileSavesTheNextVersionWithItsLineageAndKeepsTheOwnRebuttal() throws {
        let context = try EditingDatabase()
        let mine = try makeProtocol(context, rules: [bed.with(rebuttal: .some("Mine, not theirs.")), light])
        let theirs = ProtocolFile(name: "Sleep first, their way", author: "Robin", version: 4, createdAt: created,
                                  rules: [bed.with(timeOfDayMinutes: .some(21 * 60 + 30), rebuttal: .some("Their reason")),
                                          screens.with(rebuttal: .some("Also theirs"))])
        let preview = try ProtocolFileCodec.validate(try ProtocolFileCodec.encode(theirs))

        let saved = try context.store.adoptFile(preview, at: created.addingTimeInterval(300))
        #expect(saved.number == 2 && saved.protocolID == mine.id)
        #expect(saved.rules.map(\.key) == ["in-bed", "screens-off"])
        #expect(saved.rule(for: "in-bed")?.rebuttal == "Mine, not theirs.", "the person's own reason stays on the same key")
        #expect(saved.rule(for: "screens-off")?.rebuttal == nil, "a reason from a file is never used")
        let renamed = try #require(try context.store.routineProtocol(id: mine.id))
        #expect(renamed.name == "Sleep first, their way" && renamed.author == "Robin")
        #expect(renamed.lineage == ProtocolLineage(forkedFromName: "Sleep first, their way", forkedFromVersion: 4))
        #expect(renamed.createdAt == mine.createdAt, "day 1 does not move")
        #expect(try context.store.version(protocolID: mine.id, number: 1)?.rules.map(\.key) == ["in-bed", "light"])
        #expect(try context.store.protocols().count == 1)
    }

    @Test func usingAFileWithNoProtocolMakesVersionOne() throws {
        let context = try EditingDatabase()
        let preview = try ProtocolTemplate.fitnessForTheLongRun.load()
        let first = try context.store.adoptFile(preview, at: created)
        let active = try #require(try context.store.activeProtocol())
        #expect(first.number == 1 && active.routineProtocol.name == "Fitness for the long run")
        #expect(active.routineProtocol.lineage?.forkedFromName == "Fitness for the long run")
    }

    @Test func anInvalidFileChangesNothing() throws {
        let context = try EditingDatabase()
        _ = try makeProtocol(context)
        let before = try context.database.tableRowCounts()
        for bad in [Data("hello".utf8), Data(#"{"format":"loopr-protocol","schemaVersion":1}"#.utf8)] {
            #expect(throws: ProtocolFileError.self) { _ = try context.store.adoptFile(try ProtocolFileCodec.validate(bad), at: created) }
        }
        #expect(try context.database.tableRowCounts() == before)
    }

    /// ICP R2-OPT-5: a version note can tell 45 from 50, and a number in a name follows its amount.
    @Test func aMovedAmountReadsBeforeAndAfter() {
        let zone2 = ProtocolRule(key: "zone-2", title: "Zone 2, 45 min", group: .fitness,
                                 target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 45, unit: "min"), source: .band)
        let raised = zone2.with(target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 50, unit: "min"))
        #expect(ProtocolVersionDiff.summary(ProtocolVersionDiff.changes(from: [zone2], to: [raised]))
            == "Changed Zone 2, 45 min: target 45 to 50 min.")
        #expect(RoutineRuleTitle.replacingAmount(in: "Zone 2, 45 min", from: 45, to: 50) == "Zone 2, 50 min")
        #expect(RoutineRuleTitle.replacingAmount(in: "Zone 2, 45 min", from: 2, to: 3) == "Zone 3, 45 min")
        #expect(RoutineRuleTitle.replacingAmount(in: "Protein 150 g", from: 15, to: 20) == "Protein 150 g", "15 is not in 150")
        #expect(RoutineRuleTitle.replacingAmount(in: "Walk", from: 45, to: 50) == "Walk")
    }

    @Test func theDiffNamesWhatChanged() {
        let changes = ProtocolVersionDiff.changes(from: [bed, screens, light],
                                                  to: [light, bed.with(title: "Bed by 22:00"), ProtocolRule(key: "stretch", title: "Stretch")])
        #expect(ProtocolVersionDiff.summary(changes) == "Renamed In bed by 22:30 to Bed by 22:00. Removed Screens off by 21:45. Added Stretch.")
        #expect(ProtocolVersionDiff.summary(ProtocolVersionDiff.changes(from: [bed, light], to: [light, bed])) == nil, "a move is not a change")
        let cadence = ProtocolVersionDiff.changes(from: [light], to: [light.with(cadence: .some(RuleCadence(unit: .day)))])
        #expect(cadence.isEmpty, "every day is the same as no cadence")
    }
}
