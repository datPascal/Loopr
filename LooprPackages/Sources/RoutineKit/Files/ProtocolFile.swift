import Foundation

// The protocol file: rules, targets and experiment designs in one plain JSON document, so a protocol can be shared,
// changed and run. The format is documented in docs/PROTOCOL_FILES.md and is schema version 1.
//
// A file carries the plan and nothing else. It has no health data, no check history, no experiment results and nothing
// that names the person. `author` is free text the person typed themselves.

/// One experiment design: how to test one rule. It is not a started experiment, and it holds no nights or results.
public struct ProtocolExperimentDesign: Equatable, Sendable {
    public let title: String
    /// The rule the experiment switches on and off.
    public let interventionRuleKey: RuleKey
    public let design: ExperimentDesign
    public let washout: Int
    public let minimumNightsPerArm: Int
    public let plannedNights: Int
    /// The outcome and which direction is better.
    public let outcome: ExperimentMetric

    public init(title: String, interventionRuleKey: RuleKey, design: ExperimentDesign, washout: Int,
                minimumNightsPerArm: Int, plannedNights: Int, outcome: ExperimentMetric) {
        self.title = title; self.interventionRuleKey = interventionRuleKey; self.design = design; self.washout = washout
        self.minimumNightsPerArm = minimumNightsPerArm; self.plannedNights = plannedNights; self.outcome = outcome
    }

    /// The design of a started experiment, without its dates or results.
    public init(_ start: ExperimentStart) {
        self.init(title: start.title, interventionRuleKey: start.ruleKey, design: start.design, washout: start.washout,
                  minimumNightsPerArm: start.minimumNightsPerArm, plannedNights: start.plannedNights, outcome: start.outcome)
    }
}

public struct ProtocolFile: Equatable, Sendable {
    public static let format = "loopr-protocol"
    public static let schemaVersion = 1
    public static let fileExtension = "looprprotocol"
    /// The exported type declared in Info.plist. It conforms to `public.json`.
    public static let typeIdentifier = "com.loopr.protocol"

    /// Biggest file Loopr reads.
    public static let maximumBytes = 256 * 1_024
    public static let maximumRules = 50
    public static let maximumExperiments = 10
    public static let maximumNameLength = 80
    public static let maximumTitleLength = 80
    public static let maximumRebuttalLength = 280
    public static let maximumWhyLength = 280
    /// Room for a source sentence or three, with the study's name and year.
    public static let maximumEvidenceLength = 500
    public static let maximumUnitLength = 16
    public static let maximumURLLength = 300
    public static let maximumKeyLength = 64

    public let name: String
    /// Free text the person chose to put in. Never filled in by Loopr.
    public let author: String?
    /// Where this protocol was forked from.
    public let lineage: ProtocolLineage?
    /// The protocol version number the file was exported from.
    public let version: Int
    /// When that version was saved. Whole seconds.
    public let createdAt: Date
    public let rules: [ProtocolRule]
    public let experiments: [ProtocolExperimentDesign]

    public init(name: String, author: String? = nil, lineage: ProtocolLineage? = nil, version: Int, createdAt: Date,
                rules: [ProtocolRule], experiments: [ProtocolExperimentDesign] = []) {
        self.name = name; self.author = author; self.lineage = lineage; self.version = version
        self.createdAt = createdAt; self.rules = rules; self.experiments = experiments
    }

    /// A readable file name such as "sleep-first.looprprotocol".
    public var suggestedFileName: String {
        var slug = ""
        var lastWasDash = true
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar); lastWasDash = false
            } else if !lastWasDash {
                slug.append("-"); lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return "\(slug.isEmpty ? "protocol" : slug).\(Self.fileExtension)"
    }
}

/// What the person sees before they accept a file. Nothing has been saved yet.
public struct ProtocolImportPreview: Equatable, Sendable {
    public let file: ProtocolFile
    /// Fields the file had that this version of Loopr does not read, as paths such as `rules[2].mood`. They come from a
    /// newer minor revision of the format and are dropped on import.
    public let ignoredFields: [String]

    public var ruleCountsByGroup: [RuleGroup: Int] {
        file.rules.reduce(into: [:]) { $0[$1.group, default: 0] += 1 }
    }
}

/// Why a file was refused. Nothing is saved when one of these is thrown.
public enum ProtocolFileError: Error, Equatable, LocalizedError, Sendable {
    case tooLarge(bytes: Int)
    case notJSON
    case wrongFormat
    /// A schema version newer than this Loopr reads.
    case newerSchema(Int)
    /// A schema version that no Loopr has used.
    case unsupportedSchema
    case missingField(String)
    case invalidValue(String)
    case unknownMetric(rule: String, metric: String)
    case metricSourceMismatch(rule: String, metric: String)
    case duplicateRuleKey(String)
    case tooManyRules(Int)
    case tooManyExperiments(Int)
    case unknownRuleReference(experiment: Int, key: String)
    case invalidExperiment(index: Int, reason: ExperimentError)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "This file is larger than \(ProtocolFile.maximumBytes / 1_024) KB, so Loopr will not open it."
        case .notJSON, .wrongFormat: "This file is not a Loopr protocol."
        case .newerSchema: "This file needs a newer version of Loopr."
        case .unsupportedSchema: "This file uses a format version Loopr does not know."
        case .missingField(let path): "The file is missing \"\(path)\"."
        case .invalidValue(let path): "The value for \"\(path)\" is not one Loopr can use."
        case .unknownMetric(let rule, let metric): "The rule \"\(rule)\" checks \"\(metric)\", which Loopr does not know."
        case .metricSourceMismatch(let rule, let metric): "The rule \"\(rule)\" names \"\(metric)\" under a source that cannot measure it."
        case .duplicateRuleKey(let key): "Two rules share the key \"\(key)\"."
        case .tooManyRules: "This protocol has more than \(ProtocolFile.maximumRules) rules, which is more than Loopr opens."
        case .tooManyExperiments: "This protocol has more than \(ProtocolFile.maximumExperiments) experiments, which is more than Loopr opens."
        case .unknownRuleReference(let index, let key): "Experiment \(index + 1) tests \"\(key)\", and no rule has that key."
        case .invalidExperiment(let index, let reason): "Experiment \(index + 1) cannot run. \(reason.errorDescription ?? "")"
        }
    }
}
