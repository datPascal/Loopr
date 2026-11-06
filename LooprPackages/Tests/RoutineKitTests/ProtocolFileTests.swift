import DomainKit
import Foundation
import RoutineKit
import StorageKit
import Testing

private final class FileTestDatabase {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtocolFileTests-\(UUID().uuidString)")
    let database: StorageDatabase
    let store: RoutineStore
    init() throws {
        database = try StorageDatabase(url: root.appendingPathComponent("routine.sqlite"), applicationVersion: "protocol-file-tests")
        store = RoutineStore(database: database)
    }
    deinit { try? database.databasePool.close(); try? FileManager.default.removeItem(at: root) }
}

private let created = Date(timeIntervalSince1970: 1_790_000_000)

private func fullRules() -> [ProtocolRule] {
    [
        ProtocolRule(key: "in-bed", title: "In bed by 22:30", group: .sleep,
                     target: RuleTarget(kind: .atMost, metric: "in_bed_time", value: 1_350, unit: "min"),
                     timeOfDayMinutes: 21 * 60 + 45, source: .band, isEvening: true, rebuttal: "Tomorrow starts tonight."),
        ProtocolRule(key: "protein", title: "Protein, 130 grams", group: .food,
                     target: RuleTarget(kind: .atLeast, metric: "protein_g", value: 130.5, unit: "g"), source: .food,
                     why: "Muscle keeps you strong as you age.",
                     evidence: "A 2018 review in the British Journal of Sports Medicine found about 1.6 g per kg a day helped people who lift."),
        ProtocolRule(key: "zone-2", title: "Zone 2, 150 minutes a week", group: .fitness,
                     target: RuleTarget(kind: .atLeast, metric: "zone2_minutes", value: 150, unit: "min"), source: .band,
                     cadence: RuleCadence(unit: .week)),
        ProtocolRule(key: "magnesium", title: "Magnesium", group: .supplements, target: .done, timeOfDayMinutes: 21 * 60, source: .manual),
        ProtocolRule(key: "blood-test", title: "Blood test every 6 months", group: .tests,
                     target: RuleTarget(kind: .done, metric: "done"), source: .manual, cadence: RuleCadence(unit: .month, every: 6))
    ]
}

private func fullFile() -> ProtocolFile {
    ProtocolFile(name: "Sleep first, my way", author: "Sam", lineage: ProtocolLineage(forkedFromName: "sleep-first", forkedFromVersion: 3, url: "https://example.org/sleep-first"),
                 version: 7, createdAt: Date(timeIntervalSince1970: 1_790_000_123), rules: fullRules(), experiments: [
                    ProtocolExperimentDesign(title: "Magnesium and deep sleep", interventionRuleKey: "magnesium", design: .blocks(length: 7), washout: 1,
                                             minimumNightsPerArm: 7, plannedNights: 28, outcome: .deepSleep),
                    ProtocolExperimentDesign(title: "Earlier bed", interventionRuleKey: "in-bed", design: .alternatingDays, washout: 0,
                                             minimumNightsPerArm: 5, plannedNights: 14, outcome: .timeToFallAsleep),
                    ProtocolExperimentDesign(title: "Late caffeine", interventionRuleKey: "in-bed", design: .beforeAndAfter(baselineNights: 7), washout: 2,
                                             minimumNightsPerArm: 5, plannedNights: 21, outcome: .hrv)
                 ])
}

// MARK: Raw JSON helpers

private typealias JSON = [String: Any]

private func baseJSON() throws -> JSON {
    let data = try ProtocolFileCodec.encode(fullFile())
    return try #require(try JSONSerialization.jsonObject(with: data) as? JSON)
}

private func data(_ json: JSON) throws -> Data { try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) }

private func mutated(_ change: (inout JSON) -> Void) throws -> Data {
    var json = try baseJSON()
    change(&json)
    return try data(json)
}

private func editRule(_ index: Int = 0, _ change: @escaping (inout JSON) -> Void) -> (inout JSON) -> Void {
    { json in
        var rules = json["rules"] as! [JSON]
        change(&rules[index])
        json["rules"] = rules
    }
}

private func editTarget(_ index: Int = 0, _ change: @escaping (inout JSON) -> Void) -> (inout JSON) -> Void {
    editRule(index) { rule in
        var target = rule["target"] as! JSON
        change(&target)
        rule["target"] = target
    }
}

private func editExperiment(_ index: Int = 0, _ change: @escaping (inout JSON) -> Void) -> (inout JSON) -> Void {
    { json in
        var experiments = json["experiments"] as! [JSON]
        change(&experiments[index])
        json["experiments"] = experiments
    }
}

private func allKeys(_ value: Any) -> Set<String> {
    if let object = value as? JSON { return Set(object.keys).union(object.values.flatMap { allKeys($0) }) }
    if let array = value as? [Any] { return Set(array.flatMap { allKeys($0) }) }
    return []
}

private func rejects(_ data: Data, _ expected: ProtocolFileError, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        _ = try ProtocolFileCodec.validate(data)
        Issue.record("the file was accepted; expected \(expected)", sourceLocation: sourceLocation)
    } catch let error as ProtocolFileError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

struct ProtocolFileTests {
    // MARK: Round trip

    @Test func aFileWithEveryDocumentedFieldRoundTripsLosslessly() throws {
        let file = fullFile()
        let encoded = try ProtocolFileCodec.encode(file)
        let preview = try ProtocolFileCodec.validate(encoded)
        #expect(preview.file == file)
        #expect(preview.ignoredFields.isEmpty)
        #expect(try ProtocolFileCodec.encode(preview.file) == encoded, "the same file always gives the same bytes")
        #expect(preview.ruleCountsByGroup == [.sleep: 1, .food: 1, .fitness: 1, .supplements: 1, .tests: 1])
    }

    @Test func theFileSaysWhatItIs() throws {
        let json = try baseJSON()
        #expect(json["format"] as? String == "loopr-protocol" && json["schemaVersion"] as? Int == 1)
        // The expectation is built from calendar parts in UTC, so it does not depend on the machine's time zone.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fullFile().createdAt)
        let expected = String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!, parts.second!)
        #expect(expected == "2026-09-21T14:15:23Z")
        #expect(json["createdAt"] as? String == expected)
        let rule = try #require((json["rules"] as? [JSON])?.first)
        #expect(rule["timeOfDay"] as? String == "21:45" && rule["evening"] as? Bool == true)
        #expect(ProtocolFile.typeIdentifier == "com.loopr.protocol" && ProtocolFile.fileExtension == "looprprotocol")
    }

    @Test func theFileNameIsReadable() {
        #expect(fullFile().suggestedFileName == "sleep-first-my-way.looprprotocol")
        #expect(ProtocolFile(name: "  !!! ", version: 1, createdAt: created, rules: []).suggestedFileName == "protocol.looprprotocol")
    }

    @Test func aProtocolExportsAndImportsAsANewForkWithoutTouchingTheActiveOne() throws {
        let context = try FileTestDatabase()
        let mine = RoutineProtocol(name: "Mine", author: "Sam", lineage: ProtocolLineage(forkedFromName: "sleep-first", forkedFromVersion: 3, url: "https://example.org/x"),
                                   createdAt: created)
        try context.store.createProtocol(mine, rules: fullRules())
        let bumped = try context.store.saveVersion(protocolID: mine.id, rules: Array(fullRules().prefix(3)), at: created.addingTimeInterval(100))

        let file = try context.store.exportFile(protocolID: mine.id)
        #expect(file.version == 2 && file.rules == bumped.rules.map(\.withoutRebuttal) && file.name == "Mine" && file.author == "Sam" && file.lineage == mine.lineage)
        let first = try context.store.exportFile(protocolID: mine.id, version: 1)
        #expect(first.version == 1 && first.rules == fullRules().map(\.withoutRebuttal))
        #expect(!first.rules.contains { $0.rebuttal != nil }, "a rebuttal is personal text and never goes into a file")

        let preview = try ProtocolFileCodec.validate(try ProtocolFileCodec.encode(file))
        let counts = try context.database.tableRowCounts()
        let imported = try context.store.importFile(preview, at: created.addingTimeInterval(500))
        #expect(try context.store.activeProtocol()?.routineProtocol.id == mine.id, "an import never replaces the active protocol")
        let after = try context.database.tableRowCounts()
        #expect(after["routine_protocol"] == (counts["routine_protocol"] ?? 0) + 1 && after["routine_version"] == (counts["routine_version"] ?? 0) + 1)

        let copy = try #require(try context.store.routineProtocol(id: imported.id))
        #expect(copy.name == "Mine" && copy.author == "Sam" && copy.createdAt == created.addingTimeInterval(500))
        #expect(copy.lineage == ProtocolLineage(forkedFromName: "Mine", forkedFromVersion: 2))
        let versions = try context.store.versions(protocolID: imported.id)
        #expect(versions.count == 1 && versions[0].number == 1 && versions[0].rules == file.rules)
        #expect(try context.store.exportFile(protocolID: imported.id).rules == file.rules, "rules survive a full round trip")

        // Activating is a separate, explicit choice.
        let chosen = try context.store.importFile(preview, at: created.addingTimeInterval(900), activate: true)
        #expect(try context.store.activeProtocol()?.routineProtocol.id == chosen.id)
    }

    @Test func experimentDesignsTravelButResultsDoNot() throws {
        let context = try FileTestDatabase()
        let mine = RoutineProtocol(name: "Mine", createdAt: created)
        try context.store.createProtocol(mine, rules: fullRules())
        let experiments = ExperimentStore(database: context.database)
        let day = DayIdentity(year: 2026, month: 10, day: 1)
        let start = try ExperimentStart(protocolID: mine.id, title: "Magnesium and deep sleep", interventionName: "Magnesium", ruleKey: "magnesium",
                                        design: .blocks(length: 7), washout: 1, minimumNightsPerArm: 7, plannedNights: 28, outcome: .deepSleep,
                                        startDay: day, timeZoneIdentifier: "Australia/Perth", createdAt: created)
        try experiments.start(start)
        try experiments.recordNight(experimentID: start.id, day: day, adherence: .kept, outcomeValue: 61.5, otherValues: ["sleepHeartRate": 49.25], at: created)

        let file = try context.store.exportFile(protocolID: mine.id, experiments: experiments)
        #expect(file.experiments == [ProtocolExperimentDesign(title: "Magnesium and deep sleep", interventionRuleKey: "magnesium", design: .blocks(length: 7),
                                                              washout: 1, minimumNightsPerArm: 7, plannedNights: 28, outcome: .deepSleep)])
        let text = try #require(String(data: try ProtocolFileCodec.encode(file), encoding: .utf8))
        #expect(!text.contains("61.5") && !text.contains("49.25") && !text.contains("2026-10-01") && !text.contains(start.id.rawValue.uuidString))
        let preview = try ProtocolFileCodec.validate(try ProtocolFileCodec.encode(file))
        #expect(preview.file.experiments.count == 1)
        let before = try context.database.tableRowCounts()
        try context.store.importFile(preview, at: created.addingTimeInterval(10))
        #expect(try context.database.tableRowCounts()["experiment"] == before["experiment"], "an import starts no experiment")
    }

    // MARK: No health data

    @Test func anExportFromAProtocolWithHistoryCarriesNoHealthDataOrIdentifiers() throws {
        let context = try FileTestDatabase()
        let mine = RoutineProtocol(name: "Mine", author: "Sam", createdAt: created)
        try context.store.createProtocol(mine, rules: fullRules())
        let days = (1...5).map { DayIdentity(year: 2026, month: 10, day: $0) }
        for (offset, day) in days.enumerated() {
            try context.store.recordCheck(RuleCheck(ruleKey: "protein", day: day, version: 1, state: offset.isMultiple(of: 2) ? .kept : .missed, source: .food,
                                                    measuredValue: 91.123 + Double(offset), recordedAt: created), protocolID: mine.id)
            try context.store.recordCheck(RuleCheck(ruleKey: "magnesium", day: day, version: 1, state: .kept, source: .manual, recordedAt: created), protocolID: mine.id)
        }
        try context.store.overrideCheck(protocolID: mine.id, ruleKey: "protein", day: days[0], state: .missed, at: created)
        let encoded = try ProtocolFileCodec.encode(try context.store.exportFile(protocolID: mine.id))
        let text = try #require(String(data: encoded, encoding: .utf8))

        let documented: Set<String> = ["format", "schemaVersion", "name", "author", "lineage", "version", "createdAt", "rules", "experiments", "forkedFrom", "url",
                                       "key", "title", "group", "target", "timeOfDay", "evening", "rebuttal", "source", "cadence", "kind", "metric", "value", "unit", "every",
                                       "days", "times", "why", "evidence",
                                       "interventionRuleKey", "design", "length", "washout", "minimumNightsPerArm", "plannedNights", "outcome", "betterWhen"]
        #expect(allKeys(try JSONSerialization.jsonObject(with: encoded)).isSubset(of: documented))
        for forbidden in ["91.123", "92.123", "2026-10-0", "measured", "history", "recordedAt", "overrid", "state", mine.id.rawValue.uuidString, "uuid", "device", "email"] {
            #expect(!text.contains(forbidden), "\(forbidden)")
        }
        #expect(text.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", options: .regularExpression) == nil)
    }

    // MARK: Rejections

    @Test func notAProtocolFileIsRefused() throws {
        rejects(Data("hello".utf8), .notJSON)
        rejects(Data("[1, 2]".utf8), .notJSON)
        rejects(Data(), .notJSON)
        rejects(try mutated { $0["format"] = "gpx" }, .wrongFormat)
        rejects(try mutated { $0["format"] = nil }, .missingField("format"))
        rejects(try mutated { $0["format"] = 4 }, .missingField("format"))
    }

    @Test func aFutureOrUnknownSchemaVersionIsRefusedWithAClearMessage() throws {
        rejects(try mutated { $0["schemaVersion"] = 2 }, .newerSchema(2))
        rejects(try mutated { $0["schemaVersion"] = 40 }, .newerSchema(40))
        rejects(try mutated { $0["schemaVersion"] = 0 }, .unsupportedSchema)
        rejects(try mutated { $0["schemaVersion"] = -1 }, .unsupportedSchema)
        rejects(try mutated { $0["schemaVersion"] = "1" }, .invalidValue("schemaVersion"))
        rejects(try mutated { $0["schemaVersion"] = nil }, .missingField("schemaVersion"))
        #expect(ProtocolFileError.newerSchema(2).errorDescription == "This file needs a newer version of Loopr.")
        // A newer file is reported as newer even when the rest of its shape has changed.
        rejects(try data(["format": "loopr-protocol", "schemaVersion": 3, "rules": "now an object"]), .newerSchema(3))
    }

    @Test func missingRequiredFieldsAreNamed() throws {
        for key in ["name", "version", "createdAt", "rules"] {
            rejects(try mutated { $0[key] = nil }, .missingField(key))
        }
        rejects(try mutated(editRule { $0["key"] = nil }), .missingField("rules[0].key"))
        rejects(try mutated(editRule(1) { $0["title"] = nil }), .missingField("rules[1].title"))
        rejects(try mutated(editRule(1) { $0["group"] = nil }), .missingField("rules[1].group"))
        rejects(try mutated(editRule(1) { $0["source"] = nil }), .missingField("rules[1].source"))
        rejects(try mutated(editRule(1) { $0["target"] = nil }), .missingField("rules[1].target"))
        rejects(try mutated(editTarget(1) { $0["kind"] = nil }), .missingField("rules[1].target.kind"))
        rejects(try mutated(editTarget(1) { $0["value"] = nil }), .missingField("rules[1].target.value"))
        rejects(try mutated(editTarget(1) { $0["metric"] = nil }), .missingField("rules[1].target.metric"))
        rejects(try mutated { var l = $0["lineage"] as! JSON; l["forkedFrom"] = nil; $0["lineage"] = l }, .missingField("lineage.forkedFrom"))
        rejects(try mutated(editExperiment { $0["outcome"] = nil }), .missingField("experiments[0].outcome"))
        rejects(try mutated(editExperiment { $0["plannedNights"] = nil }), .missingField("experiments[0].plannedNights"))
    }

    @Test func unknownMetricsAndMetricsUnderTheWrongSourceAreRefused() throws {
        rejects(try mutated(editTarget(1) { $0["metric"] = "kale_g" }), .unknownMetric(rule: "protein", metric: "kale_g"))
        rejects(try mutated(editTarget(1) { $0["metric"] = "steps" }), .metricSourceMismatch(rule: "protein", metric: "steps"))
        rejects(try mutated(editTarget(0) { $0["metric"] = "protein_g" }), .metricSourceMismatch(rule: "in-bed", metric: "protein_g"))
        rejects(try mutated(editTarget(3) { $0["metric"] = "steps" }), .metricSourceMismatch(rule: "magnesium", metric: "steps"))
        // Every name in the vocabulary is accepted under its own source.
        for metric in RoutineMetric.allCases where metric.source != .manual {
            let json = try mutated(editRule(0) { rule in
                rule["source"] = metric.source.rawValue
                rule["target"] = ["kind": "atLeast", "metric": metric.rawValue, "value": 1] as JSON
            })
            #expect(throws: Never.self) { _ = try ProtocolFileCodec.validate(json) }
        }
    }

    @Test func supplementAndMedicationMetricsAreAcceptedUnderFood() throws {
        let longest = String(repeating: "a", count: RoutineItemMetric.maximumKeyLength)
        for metric in ["supplements_all_taken", "medication_all_taken", "supplement_adherence", "supplement_taken:vitamin-d3",
                       "medication_taken:metformin", "supplement_taken:\(longest)", "medication_taken:\(longest)"] {
            let json = try mutated(editRule(1) { rule in
                rule["group"] = "supplements"
                rule["target"] = ["kind": "atLeast", "metric": metric, "value": 1] as JSON
            })
            let preview = try ProtocolFileCodec.validate(json)
            #expect(preview.file.rules[1].target.metric == metric, "\(metric)")
        }
    }

    @Test func malformedItemMetricsAndItemMetricsUnderAnotherSourceAreRefused() throws {
        for metric in ["supplement_taken:", "supplement_taken:Vitamin D3", "supplement_taken:d3:extra", "medication_taken:met_formin",
                       "vitamin_taken:d3"] {
            rejects(try mutated(editTarget(1) { $0["metric"] = metric }), .unknownMetric(rule: "protein", metric: metric))
        }
        // A key past 48 characters makes the name longer than any metric may be.
        let tooLong = "supplement_taken:" + String(repeating: "a", count: RoutineItemMetric.maximumKeyLength + 1)
        rejects(try mutated(editTarget(1) { $0["metric"] = tooLong }), .invalidValue("rules[1].target.metric"))
        rejects(try mutated(editTarget(0) { $0["metric"] = "supplement_taken:d3" }), .metricSourceMismatch(rule: "in-bed", metric: "supplement_taken:d3"))
        rejects(try mutated(editTarget(3) { $0["metric"] = "supplements_all_taken" }),
                .metricSourceMismatch(rule: "magnesium", metric: "supplements_all_taken"))
    }

    @Test func invalidValuesAreRefused() throws {
        func invalid(_ path: String, _ change: @escaping (inout JSON) -> Void) throws { rejects(try mutated(change), .invalidValue(path)) }
        try invalid("rules[0].group", editRule { $0["group"] = "mood" })
        try invalid("rules[0].source", editRule { $0["source"] = "oracle" })
        try invalid("rules[0].target.kind", editTarget { $0["kind"] = "roughly" })
        try invalid("rules[1].target.value", editTarget(1) { $0["value"] = -1 })
        try invalid("rules[1].target.value", editTarget(1) { $0["value"] = 2_000_000_000 })
        try invalid("rules[1].target.value", editTarget(1) { $0["value"] = "130" })
        try invalid("rules[0].timeOfDay", editRule { $0["timeOfDay"] = "25:00" })
        try invalid("rules[0].timeOfDay", editRule { $0["timeOfDay"] = "9:00" })
        try invalid("rules[0].timeOfDay", editRule { $0["timeOfDay"] = "21:60" })
        try invalid("rules[0].evening", editRule { $0["evening"] = "yes" })
        try invalid("rules[0].rebuttal", editRule { $0["rebuttal"] = String(repeating: "a", count: 281) })
        try invalid("rules[0].why", editRule { $0["why"] = String(repeating: "a", count: ProtocolFile.maximumWhyLength + 1) })
        try invalid("rules[0].evidence", editRule { $0["evidence"] = String(repeating: "a", count: ProtocolFile.maximumEvidenceLength + 1) })
        try invalid("rules[0].evidence", editRule { $0["evidence"] = "Two\u{0007}bells" })
        try invalid("rules[0].evidence", editRule { $0["evidence"] = 12 })
        try invalid("rules[0].title", editRule { $0["title"] = "   " })
        try invalid("rules[0].title", editRule { $0["title"] = String(repeating: "a", count: 81) })
        try invalid("rules[0].title", editRule { $0["title"] = "Two\nlines" })
        try invalid("rules[0].key", editRule { $0["key"] = "has space" })
        try invalid("rules[0].key", editRule { $0["key"] = String(repeating: "k", count: 65) })
        try invalid("rules[2].cadence.every", editRule(2) { $0["cadence"] = ["unit": "week", "every": 0] as JSON })
        try invalid("rules[2].cadence.every", editRule(2) { $0["cadence"] = ["unit": "week", "every": 25] as JSON })
        try invalid("rules[2].cadence.unit", editRule(2) { $0["cadence"] = ["unit": "year"] as JSON })
        try invalid("rules[0].target.unit", editTarget { $0["unit"] = String(repeating: "u", count: 17) })
        try invalid("name") { $0["name"] = "" }
        try invalid("name") { $0["name"] = String(repeating: "n", count: 81) }
        try invalid("name") { $0["name"] = 12 }
        try invalid("version") { $0["version"] = 0 }
        try invalid("version") { $0["version"] = 1.5 }
        try invalid("createdAt") { $0["createdAt"] = "yesterday" }
        try invalid("createdAt") { $0["createdAt"] = "2026-09-21" }
        try invalid("lineage.url") { var l = $0["lineage"] as! JSON; l["url"] = "http://example.org"; $0["lineage"] = l }
        try invalid("lineage.url") { var l = $0["lineage"] as! JSON; l["url"] = "not a url"; $0["lineage"] = l }
        try invalid("lineage.version") { var l = $0["lineage"] as! JSON; l["version"] = 0; $0["lineage"] = l }
        try invalid("rules") { $0["rules"] = "none" }
        try invalid("experiments[0].design", editExperiment { $0["design"] = ["kind": "blocks"] as JSON })
        try invalid("experiments[0].design", editExperiment { $0["design"] = ["kind": "alternating", "length": 3] as JSON })
        try invalid("experiments[0].design", editExperiment { $0["design"] = ["kind": "zigzag"] as JSON })
        try invalid("experiments[0].outcome.betterWhen", editExperiment { var o = $0["outcome"] as! JSON; o["betterWhen"] = "sideways"; $0["outcome"] = o })
        try invalid("experiments[0].outcome.metric", editExperiment { var o = $0["outcome"] as! JSON; o["metric"] = "has space"; $0["outcome"] = o })
    }

    @Test func duplicateRuleKeysAreRefused() throws {
        rejects(try mutated { json in
            var rules = json["rules"] as! [JSON]
            rules[1]["key"] = rules[0]["key"]
            json["rules"] = rules
        }, .duplicateRuleKey("in-bed"))
    }

    @Test func experimentsMustBeAPlanThatCanRun() throws {
        rejects(try mutated(editExperiment { $0["interventionRuleKey"] = "nothing" }), .unknownRuleReference(experiment: 0, key: "nothing"))
        rejects(try mutated(editExperiment(1) { $0["minimumNightsPerArm"] = 1 }), .invalidExperiment(index: 1, reason: .minimumNightsTooLow))
        rejects(try mutated(editExperiment(1) { $0["plannedNights"] = 1 }), .invalidExperiment(index: 1, reason: .plannedNightsTooLow))
        rejects(try mutated(editExperiment(0) { $0["washout"] = 7 }), .invalidExperiment(index: 0, reason: .invalidWashout))
        rejects(try mutated(editExperiment(2) { $0["design"] = ["kind": "beforeAfter", "length": 21] as JSON }), .invalidExperiment(index: 2, reason: .invalidDesign))
        // Blocks start with the on arm: 10 nights give it 7 and leave the off arm 3, less a washout, short of 7.
        rejects(try mutated(editExperiment(0) { $0["plannedNights"] = 10 }), .invalidExperiment(index: 0, reason: .planCannotReachMinimum(.off)))
        // When both arms fall short the validator names the on arm first. Its order is on, then off.
        rejects(try mutated(editExperiment(0) { $0["plannedNights"] = 5 }), .invalidExperiment(index: 0, reason: .planCannotReachMinimum(.on)))
    }

    @Test func limitsOnSizeAndCountAreEnforced() throws {
        #expect(ProtocolFile.maximumBytes == 262_144 && ProtocolFile.maximumRules == 50 && ProtocolFile.maximumExperiments == 10)
        let big = Data(repeating: 0x20, count: ProtocolFile.maximumBytes + 1)
        rejects(big, .tooLarge(bytes: ProtocolFile.maximumBytes + 1))
        // A valid file padded to exactly the limit is still read.
        var padded = try ProtocolFileCodec.encode(fullFile())
        padded.append(Data(repeating: 0x20, count: ProtocolFile.maximumBytes - padded.count))
        #expect(padded.count == ProtocolFile.maximumBytes)
        #expect(try ProtocolFileCodec.validate(padded).file == fullFile())

        func rules(_ count: Int) -> [JSON] {
            (0..<count).map { ["key": "r\($0)", "title": "Rule \($0)", "group": "custom", "source": "manual", "target": ["kind": "done"]] as JSON }
        }
        rejects(try mutated { $0["rules"] = rules(51); $0["experiments"] = nil }, .tooManyRules(51))
        let fifty = try mutated { $0["rules"] = rules(50); $0["experiments"] = nil }
        #expect(try ProtocolFileCodec.validate(fifty).file.rules.count == 50)
        let experiment = (try baseJSON()["experiments"] as! [JSON])[0]
        rejects(try mutated { json in
            json["rules"] = rules(2) + [["key": "magnesium", "title": "M", "group": "custom", "source": "manual", "target": ["kind": "done"]] as JSON]
            json["experiments"] = Array(repeating: experiment, count: 11)
        }, .tooManyExperiments(11))
    }

    @Test func everyErrorHasAPlainMessage() {
        let errors: [ProtocolFileError] = [
            .tooLarge(bytes: 1), .notJSON, .wrongFormat, .newerSchema(2), .unsupportedSchema, .missingField("name"), .invalidValue("name"),
            .unknownMetric(rule: "a", metric: "b"), .metricSourceMismatch(rule: "a", metric: "b"), .duplicateRuleKey("a"), .tooManyRules(51),
            .tooManyExperiments(11), .unknownRuleReference(experiment: 0, key: "a"), .invalidExperiment(index: 0, reason: .invalidWashout)
        ]
        for error in errors {
            let message = error.errorDescription ?? ""
            #expect(!message.isEmpty && !message.contains("!") && !message.contains("\u{2014}") && message.hasSuffix("."), "\(error)")
        }
        #expect(ProtocolFileError.tooLarge(bytes: 1).errorDescription == "This file is larger than 256 KB, so Loopr will not open it.")
    }

    // MARK: No side effects

    @Test func aRefusedFileLeavesTheStoreExactlyAsItWas() throws {
        let context = try FileTestDatabase()
        let mine = RoutineProtocol(name: "Mine", createdAt: created)
        try context.store.createProtocol(mine, rules: fullRules())
        try context.store.recordCheck(RuleCheck(ruleKey: "protein", day: DayIdentity(year: 2026, month: 10, day: 1), version: 1, state: .kept, source: .food,
                                                measuredValue: 140, recordedAt: created), protocolID: mine.id)
        let tables = try context.database.schemaSnapshot().tables.map(\.name)
        func snapshot() throws -> [String: [[DatabaseValue]]] {
            try context.database.read { db in
                var result: [String: [[DatabaseValue]]] = [:]
                for table in tables {
                    result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\" ORDER BY rowid").map { Array($0.databaseValues) }
                }
                return result
            }
        }
        let before = try snapshot()

        func open(_ data: Data) throws {
            let preview = try ProtocolFileCodec.validate(data)
            try context.store.importFile(preview, at: created)
        }
        let bad: [Data] = [
            Data("hello".utf8), Data(repeating: 0x20, count: ProtocolFile.maximumBytes + 1),
            try mutated { $0["format"] = "x" }, try mutated { $0["schemaVersion"] = 2 }, try mutated { $0["name"] = nil },
            try mutated(editTarget(1) { $0["metric"] = "kale_g" }), try mutated(editTarget(1) { $0["value"] = -3 }),
            try mutated { var r = $0["rules"] as! [JSON]; r[1]["key"] = r[0]["key"]; $0["rules"] = r },
            try mutated(editExperiment { $0["interventionRuleKey"] = "nothing" }), try mutated { $0["version"] = 0 }
        ]
        for file in bad {
            #expect(throws: ProtocolFileError.self) { try open(file) }
            #expect(try snapshot() == before)
        }
    }

    // MARK: Newer minor revisions

    @Test func unknownOptionalFieldsAreIgnoredAndReported() throws {
        let file = try mutated { json in
            json["futureThing"] = ["a": 1]
            var lineage = json["lineage"] as! JSON
            lineage["mirror"] = "https://example.org"
            json["lineage"] = lineage
            var rules = json["rules"] as! [JSON]
            rules[2]["mood"] = "tired"
            var target = rules[1]["target"] as! JSON
            target["tolerance"] = 0.1
            rules[1]["target"] = target
            var cadence = rules[2]["cadence"] as! JSON
            cadence["anchor"] = "monday"
            rules[2]["cadence"] = cadence
            json["rules"] = rules
            var experiments = json["experiments"] as! [JSON]
            experiments[0]["notes"] = "x"
            var outcome = experiments[0]["outcome"] as! JSON
            outcome["scale"] = "log"
            experiments[0]["outcome"] = outcome
            json["experiments"] = experiments
        }
        let preview = try ProtocolFileCodec.validate(file)
        #expect(preview.file == fullFile(), "what Loopr reads is unchanged")
        #expect(Set(preview.ignoredFields) == ["futureThing", "lineage.mirror", "rules[2].mood", "rules[1].target.tolerance", "rules[2].cadence.anchor",
                                               "experiments[0].notes", "experiments[0].outcome.scale"])
        // The fields are dropped when the file is saved again.
        let text = try #require(String(data: try ProtocolFileCodec.encode(preview.file), encoding: .utf8))
        #expect(!text.contains("futureThing") && !text.contains("tolerance"))
    }

    @Test func aPlainJSONFileThatValidatesIsAccepted() throws {
        // The extension is not part of validation, so a .json file is read the same way.
        let json = try data(try baseJSON())
        #expect(try ProtocolFileCodec.validate(json).file == fullFile())
    }

    // MARK: Cadence

    @Test func aRulesCadenceSurvivesTheStoreAndOldPayloadsStillDecode() throws {
        let context = try FileTestDatabase()
        let mine = RoutineProtocol(name: "Mine", createdAt: created)
        try context.store.createProtocol(mine, rules: fullRules())
        #expect(try context.store.latestVersion(protocolID: mine.id)?.rules == fullRules())
        let old = #"{"key":"walk","title":"Walk","group":"custom","target":{"kind":"done"},"source":"manual"}"#
        let rule = try JSONDecoder().decode(ProtocolRule.self, from: Data(old.utf8))
        #expect(rule.cadence == nil)
        #expect(rule.why == nil, "a rule saved before why existed decodes without one")
        #expect(rule.evidence == nil, "a rule saved before evidence existed decodes without one")
        let lineage = try JSONDecoder().decode(ProtocolLineage.self, from: Data(#"{"forkedFromName":"a","forkedFromVersion":2}"#.utf8))
        #expect(lineage.url == nil)
    }

    @Test func aWeeklyRuleCheckedByASourceIsUnknownOnTheDayViewAndAManualOneStillTicks() throws {
        let zone = TimeZone(identifier: "Australia/Perth")!
        let day = DayIdentity(year: 2026, month: 10, day: 20)
        let clock = try #require(RoutineDayClock(day: day, timeZone: zone))
        let context = try RoutineEvaluationContext(day: day, now: clock.end, timeZone: zone)
        let weekly = fullRules()[2]
        let sources = RoutineSourceSnapshots(band: RoutineSourceSnapshot(source: .band, readings: [.zone2Minutes: .measured(200)]))
        let outcome = RuleEvaluator.evaluate(weekly, context: context, sources: sources)
        #expect(outcome.state == .unknown && outcome.reason == .longerPeriod, "one day cannot score a weekly total")
        let blood = fullRules()[4]
        let ticked = RoutineSourceSnapshots(manual: RoutineManualSnapshot(ticked: ["blood-test"]))
        #expect(RuleEvaluator.evaluate(blood, context: context, sources: ticked).state == .kept)
    }

    // MARK: Evidence

    /// ICP R2-NEW-07, R2-DES-02: a rule's source travels with the file next to its short why, survives the store and a
    /// second save, and a payload from round 1, with a why and no evidence, still decodes unchanged.
    @Test func evidenceTravelsInFilesAndARound1PayloadStillDecodes() throws {
        let preview = try ProtocolFileCodec.validate(try ProtocolFileCodec.encode(fullFile()))
        let protein = try #require(preview.file.rules.first { $0.key == "protein" })
        #expect(protein.why == "Muscle keeps you strong as you age.")
        #expect(protein.evidence?.hasPrefix("A 2018 review") == true && preview.ignoredFields.isEmpty)

        let context = try FileTestDatabase()
        let imported = try context.store.importFile(preview, at: created)
        let saved = try #require(try context.store.latestVersion(protocolID: imported.id)?.rule(for: "protein"))
        #expect(saved.evidence == protein.evidence, "the store keeps it")
        let text = try #require(String(data: try ProtocolFileCodec.encode(try context.store.exportFile(protocolID: imported.id)), encoding: .utf8))
        #expect(text.contains("\"evidence\""), "an export writes it again")

        let round1 = #"{"key":"in-bed","title":"In bed by 22:30","group":"sleep","target":{"kind":"atMost","metric":"in_bed_time","value":1350,"unit":"min"},"timeOfDayMinutes":1305,"source":"band","isEvening":true,"why":"The American Academy of Sleep Medicine says adults need 7 to 9 hours."}"#
        let old = try JSONDecoder().decode(ProtocolRule.self, from: Data(round1.utf8))
        #expect(old.why == "The American Academy of Sleep Medicine says adults need 7 to 9 hours." && old.evidence == nil)
        #expect(old.timeOfDayMinutes == 1_305 && old.isEvening && old.source == .band)
        // Encoding a rule without evidence leaves the key out, so the stored payload keeps its round 1 shape.
        let encoded = try #require(String(data: try JSONEncoder().encode(old), encoding: .utf8))
        #expect(!encoded.contains("evidence"))
    }
}
