import Foundation

/// Reads and writes protocol files. `validate` has no side effects: it either returns a preview or throws, and it never
/// touches a store. `RoutineStore.importFile` is the only thing that saves.
public enum ProtocolFileCodec {
    // MARK: Validate

    public static func validate(_ data: Data) throws -> ProtocolImportPreview {
        guard data.count <= ProtocolFile.maximumBytes else { throw ProtocolFileError.tooLarge(bytes: data.count) }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let top) = root else {
            throw ProtocolFileError.notJSON
        }
        var parser = Parser()
        let file = try parser.file(top)
        return ProtocolImportPreview(file: file, ignoredFields: parser.ignored)
    }

    // MARK: Encode

    /// The file as JSON text. Keys are sorted, so the same file always gives the same bytes. Key order carries no meaning.
    public static func encode(_ file: ProtocolFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(FileDTO(file))
    }

    /// The file for one protocol version, with the designs of the experiments run on the protocol. It carries rules and
    /// designs only. A rebuttal is the person's own text, so it never goes into a file (LV-07.4).
    public static func file(for routineProtocol: RoutineProtocol, version: ProtocolVersion,
                            experiments: [ProtocolExperimentDesign] = []) -> ProtocolFile {
        ProtocolFile(name: routineProtocol.name, author: routineProtocol.author, lineage: routineProtocol.lineage,
                     version: version.number, createdAt: Date(timeIntervalSince1970: version.createdAt.timeIntervalSince1970.rounded(.down)),
                     rules: version.rules.map(\.withoutRebuttal), experiments: experiments)
    }

    // MARK: Dates

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(from text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.timeZone = TimeZone(secondsFromGMT: 0)
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    // MARK: Output shape

    private struct FileDTO: Encodable {
        struct Lineage: Encodable { let forkedFrom: String; let version: Int?; let url: String? }
        struct Target: Encodable { let kind: String; let metric: String?; let value: Double?; let unit: String? }
        struct Cadence: Encodable { let unit: String; let every: Int; let days: [String]?; let times: Int? }
        struct Rule: Encodable {
            let key: String; let title: String; let group: String; let target: Target; let timeOfDay: String?
            let evening: Bool?; let rebuttal: String?; let source: String; let cadence: Cadence?; let why: String?
            let evidence: String?
        }
        struct Design: Encodable { let kind: String; let length: Int? }
        struct Outcome: Encodable { let metric: String; let title: String; let unit: String; let betterWhen: String }
        struct Experiment: Encodable {
            let title: String; let interventionRuleKey: String; let design: Design; let washout: Int
            let minimumNightsPerArm: Int; let plannedNights: Int; let outcome: Outcome
        }

        let format = ProtocolFile.format
        let schemaVersion = ProtocolFile.schemaVersion
        let name: String
        let author: String?
        let lineage: Lineage?
        let version: Int
        let createdAt: String
        let rules: [Rule]
        let experiments: [Experiment]?

        init(_ file: ProtocolFile) {
            name = file.name; author = file.author
            lineage = file.lineage.map { Lineage(forkedFrom: $0.forkedFromName, version: $0.forkedFromVersion, url: $0.url) }
            version = file.version
            createdAt = ProtocolFileCodec.string(from: file.createdAt)
            rules = file.rules.map { rule in
                Rule(key: rule.key.rawValue, title: rule.title, group: rule.group.rawValue,
                     target: Target(kind: rule.target.kind.rawValue, metric: rule.target.metric, value: rule.target.value, unit: rule.target.unit),
                     timeOfDay: rule.timeOfDayMinutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) },
                     evening: rule.isEvening ? true : nil, rebuttal: rule.rebuttal, source: rule.source.rawValue,
                     cadence: rule.cadence.map {
                         Cadence(unit: $0.unit.rawValue, every: $0.every, days: $0.days.isEmpty ? nil : $0.days.map(\.rawValue),
                                 times: $0.timesPerWeek)
                     }, why: rule.why, evidence: rule.evidence)
            }
            experiments = file.experiments.isEmpty ? nil : file.experiments.map { design in
                Experiment(title: design.title, interventionRuleKey: design.interventionRuleKey.rawValue,
                           design: Design(kind: design.design.kind, length: design.design.length), washout: design.washout,
                           minimumNightsPerArm: design.minimumNightsPerArm, plannedNights: design.plannedNights,
                           outcome: Outcome(metric: design.outcome.key, title: design.outcome.title, unit: design.outcome.unit,
                                            betterWhen: design.outcome.benefit.rawValue))
            }
        }
    }

    // MARK: Input

    /// A JSON value of any shape, so the parser can name what is wrong and what it does not recognise.
    indirect enum JSONValue: Decodable {
        case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int.self) { self = .int(value) }
            else if let value = try? container.decode(Double.self) { self = .double(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else { self = .object(try container.decode([String: JSONValue].self)) }
        }
    }

    private struct Parser {
        var ignored: [String] = []

        typealias Object = [String: JSONValue]

        // MARK: Field readers

        private mutating func noteUnknown(_ object: Object, known: Set<String>, path: String) {
            for key in object.keys.sorted() where !known.contains(key) {
                ignored.append(path.isEmpty ? key : "\(path).\(key)")
            }
        }

        private func field(_ object: Object, _ key: String, _ path: String) -> JSONValue? {
            if case .null? = object[key] { return nil }
            return object[key]
        }

        private func required(_ object: Object, _ key: String, _ path: String) throws -> JSONValue {
            guard let value = field(object, key, path) else { throw ProtocolFileError.missingField(path.isEmpty ? key : "\(path).\(key)") }
            return value
        }

        private func name(_ key: String, _ path: String) -> String {
            if key.isEmpty { return path }
            return path.isEmpty ? key : "\(path).\(key)"
        }

        private func text(_ value: JSONValue, _ key: String, _ path: String, maximum: Int, allowBlank: Bool = false) throws -> String {
            guard case .string(let string) = value else { throw ProtocolFileError.invalidValue(name(key, path)) }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard string.count <= maximum, allowBlank || !trimmed.isEmpty,
                  !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ProtocolFileError.invalidValue(name(key, path))
            }
            return string
        }

        private func requiredText(_ object: Object, _ key: String, _ path: String, maximum: Int) throws -> String {
            try text(try required(object, key, path), key, path, maximum: maximum)
        }

        private func optionalText(_ object: Object, _ key: String, _ path: String, maximum: Int) throws -> String? {
            try field(object, key, path).map { try text($0, key, path, maximum: maximum) }
        }

        private func integer(_ value: JSONValue, _ key: String, _ path: String, range: ClosedRange<Int>) throws -> Int {
            guard case .int(let number) = value, range.contains(number) else { throw ProtocolFileError.invalidValue(name(key, path)) }
            return number
        }

        private func requiredInt(_ object: Object, _ key: String, _ path: String, range: ClosedRange<Int>) throws -> Int {
            try integer(try required(object, key, path), key, path, range: range)
        }

        private func number(_ value: JSONValue, _ key: String, _ path: String) throws -> Double {
            let result: Double
            switch value {
            case .int(let number): result = Double(number)
            case .double(let number): result = number
            default: throw ProtocolFileError.invalidValue(name(key, path))
            }
            guard result.isFinite, result >= 0, result <= 1_000_000_000 else { throw ProtocolFileError.invalidValue(name(key, path)) }
            return result
        }

        private func object(_ value: JSONValue, _ key: String, _ path: String) throws -> Object {
            guard case .object(let object) = value else { throw ProtocolFileError.invalidValue(name(key, path)) }
            return object
        }

        private func array(_ value: JSONValue, _ key: String, _ path: String) throws -> [JSONValue] {
            guard case .array(let array) = value else { throw ProtocolFileError.invalidValue(name(key, path)) }
            return array
        }

        private func isKey(_ text: String) -> Bool {
            !text.isEmpty && text.count <= ProtocolFile.maximumKeyLength
                && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
        }

        // MARK: File

        mutating func file(_ top: Object) throws -> ProtocolFile {
            guard case .string(let format)? = field(top, "format", "") else { throw ProtocolFileError.missingField("format") }
            guard format == ProtocolFile.format else { throw ProtocolFileError.wrongFormat }
            guard let versionValue = field(top, "schemaVersion", "") else { throw ProtocolFileError.missingField("schemaVersion") }
            guard case .int(let schema) = versionValue else { throw ProtocolFileError.invalidValue("schemaVersion") }
            if schema > ProtocolFile.schemaVersion { throw ProtocolFileError.newerSchema(schema) }
            guard schema == ProtocolFile.schemaVersion else { throw ProtocolFileError.unsupportedSchema }

            let known: Set<String> = ["format", "schemaVersion", "name", "author", "lineage", "version", "createdAt", "rules", "experiments"]
            noteUnknown(top, known: known, path: "")

            let name = try requiredText(top, "name", "", maximum: ProtocolFile.maximumNameLength)
            let author = try optionalText(top, "author", "", maximum: ProtocolFile.maximumNameLength)
            let lineage = try field(top, "lineage", "").map { try self.lineage($0) }
            let version = try requiredInt(top, "version", "", range: 1...1_000_000)
            let createdText = try requiredText(top, "createdAt", "", maximum: 40)
            guard let createdAt = ProtocolFileCodec.date(from: createdText) else { throw ProtocolFileError.invalidValue("createdAt") }

            let ruleValues = try array(try required(top, "rules", ""), "rules", "")
            guard ruleValues.count <= ProtocolFile.maximumRules else { throw ProtocolFileError.tooManyRules(ruleValues.count) }
            var rules: [ProtocolRule] = []
            var keys = Set<String>()
            for (index, value) in ruleValues.enumerated() {
                let rule = try self.rule(value, path: "rules[\(index)]")
                guard keys.insert(rule.key.rawValue).inserted else { throw ProtocolFileError.duplicateRuleKey(rule.key.rawValue) }
                rules.append(rule)
            }

            var experiments: [ProtocolExperimentDesign] = []
            if let value = field(top, "experiments", "") {
                let values = try array(value, "experiments", "")
                guard values.count <= ProtocolFile.maximumExperiments else { throw ProtocolFileError.tooManyExperiments(values.count) }
                for (index, value) in values.enumerated() {
                    experiments.append(try experiment(value, index: index, ruleKeys: keys))
                }
            }
            return ProtocolFile(name: name, author: author.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
                                lineage: lineage, version: version,
                                createdAt: createdAt, rules: rules, experiments: experiments)
        }

        private mutating func lineage(_ value: JSONValue) throws -> ProtocolLineage {
            let object = try self.object(value, "lineage", "")
            noteUnknown(object, known: ["forkedFrom", "version", "url"], path: "lineage")
            let name = try requiredText(object, "forkedFrom", "lineage", maximum: ProtocolFile.maximumNameLength)
            let version = try field(object, "version", "lineage").map { try integer($0, "version", "lineage", range: 1...1_000_000) }
            var url: String?
            if let value = field(object, "url", "lineage") {
                let text = try self.text(value, "url", "lineage", maximum: ProtocolFile.maximumURLLength)
                guard let parsed = URL(string: text), parsed.scheme?.lowercased() == "https", parsed.host?.isEmpty == false else {
                    throw ProtocolFileError.invalidValue("lineage.url")
                }
                url = text
            }
            return ProtocolLineage(forkedFromName: name, forkedFromVersion: version, url: url)
        }

        // MARK: Rules

        private mutating func rule(_ value: JSONValue, path: String) throws -> ProtocolRule {
            let object = try self.object(value, "", path)
            noteUnknown(object, known: ["key", "title", "group", "target", "timeOfDay", "evening", "rebuttal", "source", "cadence", "why", "evidence"],
                    path: path)
            let keyText = try requiredText(object, "key", path, maximum: ProtocolFile.maximumKeyLength)
            guard isKey(keyText) else { throw ProtocolFileError.invalidValue("\(path).key") }
            let title = try requiredText(object, "title", path, maximum: ProtocolFile.maximumTitleLength)
            guard case .string(let groupText) = try required(object, "group", path), let group = RuleGroup(rawValue: groupText) else {
                throw ProtocolFileError.invalidValue("\(path).group")
            }
            guard case .string(let sourceText) = try required(object, "source", path), let source = CheckSource(rawValue: sourceText) else {
                throw ProtocolFileError.invalidValue("\(path).source")
            }
            let target = try self.target(try required(object, "target", path), path: "\(path).target", rule: keyText, source: source)

            var minutes: Int?
            if let value = field(object, "timeOfDay", path) {
                guard case .string(let clock) = value else { throw ProtocolFileError.invalidValue("\(path).timeOfDay") }
                minutes = try Self.minutes(fromClock: clock, path: "\(path).timeOfDay")
            }
            var evening = false
            if let value = field(object, "evening", path) {
                guard case .bool(let flag) = value else { throw ProtocolFileError.invalidValue("\(path).evening") }
                evening = flag
            }
            let rebuttal = try optionalText(object, "rebuttal", path, maximum: ProtocolFile.maximumRebuttalLength)
            let why = try optionalText(object, "why", path, maximum: ProtocolFile.maximumWhyLength)
            let evidence = try optionalText(object, "evidence", path, maximum: ProtocolFile.maximumEvidenceLength)
            var cadence: RuleCadence?
            if let value = field(object, "cadence", path) {
                cadence = try self.cadence(value, path: "\(path).cadence")
            }
            return ProtocolRule(key: RuleKey(rawValue: keyText), title: title, group: group, target: target, timeOfDayMinutes: minutes,
                                source: source, isEvening: evening, rebuttal: rebuttal, cadence: cadence, why: why,
                                evidence: evidence)
        }

        private mutating func target(_ value: JSONValue, path: String, rule: String, source: CheckSource) throws -> RuleTarget {
            let object = try self.object(value, "", path)
            noteUnknown(object, known: ["kind", "metric", "value", "unit"], path: path)
            guard case .string(let kindText) = try required(object, "kind", path), let kind = RuleTargetKind(rawValue: kindText) else {
                throw ProtocolFileError.invalidValue("\(path).kind")
            }
            // An item name is its prefix and a stack key of up to 48 characters, so it may run past a rule key's limit.
            let longestItem = RoutineItemMetric.Kind.allCases.map { $0.rawValue.count + 1 }.max()! + RoutineItemMetric.maximumKeyLength
            let metric = try optionalText(object, "metric", path, maximum: max(ProtocolFile.maximumKeyLength, longestItem))
            if source == .manual {
                // A tick has nothing to measure. The vocabulary's own name for it is allowed.
                if let metric, metric != RoutineMetric.done.rawValue { throw ProtocolFileError.metricSourceMismatch(rule: rule, metric: metric) }
            } else {
                guard let metric else { throw ProtocolFileError.missingField("\(path).metric") }
                // The fixed names and the item names (`supplement_taken:<key>`, `medication_taken:<key>`).
                guard let known = RoutineMetricVocabulary.source(ofMetric: metric) else { throw ProtocolFileError.unknownMetric(rule: rule, metric: metric) }
                guard known == source else { throw ProtocolFileError.metricSourceMismatch(rule: rule, metric: metric) }
            }
            var amount: Double?
            if let value = field(object, "value", path) { amount = try number(value, "value", path) }
            if kind != .done && amount == nil { throw ProtocolFileError.missingField("\(path).value") }
            let unit = try optionalText(object, "unit", path, maximum: ProtocolFile.maximumUnitLength)
            return RuleTarget(kind: kind, metric: metric, value: amount, unit: unit)
        }

        /// `days` goes with a daily cadence and `times` with a weekly one. All seven days read as every day, and
        /// `times` of 1 as each week. An app from before these fields lists them as ignored and reads the rule as
        /// every day or each week.
        private mutating func cadence(_ value: JSONValue, path: String) throws -> RuleCadence {
            let object = try self.object(value, "", path)
            noteUnknown(object, known: ["unit", "every", "days", "times"], path: path)
            guard case .string(let unitText) = try required(object, "unit", path), let unit = RuleCadence.Unit(rawValue: unitText) else {
                throw ProtocolFileError.invalidValue("\(path).unit")
            }
            let every = try field(object, "every", path).map { try integer($0, "every", path, range: 1...RuleCadence.largestEvery) } ?? 1
            if let value = field(object, "days", path) {
                guard unit == .day, every == 1 else { throw ProtocolFileError.invalidValue("\(path).days") }
                let names = try array(value, "days", path)
                guard !names.isEmpty, names.count <= 7 else { throw ProtocolFileError.invalidValue("\(path).days") }
                let days = try names.map { name -> RuleWeekday in
                    guard case .string(let text) = name, let day = RuleWeekday(rawValue: text) else {
                        throw ProtocolFileError.invalidValue("\(path).days")
                    }
                    return day
                }
                guard Set(days).count == days.count else { throw ProtocolFileError.invalidValue("\(path).days") }
                return RuleCadence.on(Set(days))
            }
            if let value = field(object, "times", path) {
                guard unit == .week, every == 1 else { throw ProtocolFileError.invalidValue("\(path).times") }
                return RuleCadence.timesAWeek(try integer(value, "times", path, range: 1...7))
            }
            return RuleCadence(unit: unit, every: every)
        }

        private static func minutes(fromClock text: String, path: String) throws -> Int {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0..<24).contains(hour), (0..<60).contains(minute) else { throw ProtocolFileError.invalidValue(path) }
            return hour * 60 + minute
        }

        // MARK: Experiments

        private mutating func experiment(_ value: JSONValue, index: Int, ruleKeys: Set<String>) throws -> ProtocolExperimentDesign {
            let path = "experiments[\(index)]"
            let object = try self.object(value, "", path)
            noteUnknown(object, known: ["title", "interventionRuleKey", "design", "washout", "minimumNightsPerArm", "plannedNights", "outcome"], path: path)
            let title = try requiredText(object, "title", path, maximum: ProtocolFile.maximumTitleLength)
            let ruleKey = try requiredText(object, "interventionRuleKey", path, maximum: ProtocolFile.maximumKeyLength)
            guard ruleKeys.contains(ruleKey) else { throw ProtocolFileError.unknownRuleReference(experiment: index, key: ruleKey) }

            let designObject = try self.object(try required(object, "design", path), "design", path)
            noteUnknown(designObject, known: ["kind", "length"], path: "\(path).design")
            guard case .string(let kind) = try required(designObject, "kind", "\(path).design") else {
                throw ProtocolFileError.invalidValue("\(path).design.kind")
            }
            let length = try field(designObject, "length", "\(path).design").map { try integer($0, "length", "\(path).design", range: 0...1_000) }
            guard let design = ExperimentDesign(kind: kind, length: length) else { throw ProtocolFileError.invalidValue("\(path).design") }

            let washout = try requiredInt(object, "washout", path, range: 0...1_000)
            let minimum = try requiredInt(object, "minimumNightsPerArm", path, range: 0...1_000)
            let planned = try requiredInt(object, "plannedNights", path, range: 0...1_000)

            let outcomeObject = try self.object(try required(object, "outcome", path), "outcome", path)
            noteUnknown(outcomeObject, known: ["metric", "title", "unit", "betterWhen"], path: "\(path).outcome")
            let metric = try requiredText(outcomeObject, "metric", "\(path).outcome", maximum: ProtocolFile.maximumKeyLength)
            guard isKey(metric) else { throw ProtocolFileError.invalidValue("\(path).outcome.metric") }
            let outcomeTitle = try requiredText(outcomeObject, "title", "\(path).outcome", maximum: ProtocolFile.maximumTitleLength)
            let unit = try text(try required(outcomeObject, "unit", "\(path).outcome"), "unit", "\(path).outcome",
                                maximum: ProtocolFile.maximumUnitLength, allowBlank: true)
            guard case .string(let better) = try required(outcomeObject, "betterWhen", "\(path).outcome"),
                  let benefit = ExperimentBenefit(rawValue: better) else { throw ProtocolFileError.invalidValue("\(path).outcome.betterWhen") }

            guard minimum >= ExperimentStart.smallestMinimumNightsPerArm else {
                throw ProtocolFileError.invalidExperiment(index: index, reason: .minimumNightsTooLow)
            }
            do {
                try ExperimentSchedule.validate(design: design, washout: washout, plannedNights: planned, minimumNightsPerArm: minimum)
            } catch let reason as ExperimentError {
                throw ProtocolFileError.invalidExperiment(index: index, reason: reason)
            }
            return ProtocolExperimentDesign(title: title, interventionRuleKey: RuleKey(rawValue: ruleKey), design: design, washout: washout,
                                            minimumNightsPerArm: minimum, plannedNights: planned,
                                            outcome: ExperimentMetric(key: metric, title: outcomeTitle, unit: unit, benefit: benefit))
        }
    }
}

// MARK: - Store

extension RoutineStore {
    /// The file for a protocol, at `version` or its newest version. Designs come from `experiments` when given: every
    /// experiment started on this protocol, as a design only.
    public func exportFile(protocolID: ProtocolID, version: Int? = nil, experiments: ExperimentStore? = nil) throws -> ProtocolFile {
        guard let routineProtocol = try self.routineProtocol(id: protocolID) else { throw RoutineError.missingProtocol }
        let saved: ProtocolVersion?
        if let version { saved = try self.version(protocolID: protocolID, number: version) }
        else { saved = try latestVersion(protocolID: protocolID) }
        guard let saved else { throw RoutineError.missingVersion }
        let designs = try experiments?.experiments().filter { $0.start.protocolID == protocolID }
            .map { ProtocolExperimentDesign($0.start) } ?? []
        return ProtocolFileCodec.file(for: routineProtocol, version: saved, experiments: designs)
    }

    /// Saves a validated file as a new protocol with version 1. The new protocol is a fork of the file: its lineage names
    /// the file and the version the file was exported from. It is not made active unless `activate` is true, so an import
    /// never replaces the person's protocol on its own. Experiment designs are not saved; the experiment screen starts them.
    /// A rebuttal in the file is dropped: a rebuttal is text the person writes for themselves.
    @discardableResult
    public func importFile(_ preview: ProtocolImportPreview, at date: Date, activate: Bool = false) throws -> RoutineProtocol {
        let file = preview.file
        let created = RoutineProtocol(name: file.name, author: file.author,
                                      lineage: ProtocolLineage(forkedFromName: file.name, forkedFromVersion: file.version),
                                      createdAt: date)
        try createProtocol(created, rules: file.rules.map(\.withoutRebuttal), note: "Imported from a file.", activate: activate)
        return created
    }
}
