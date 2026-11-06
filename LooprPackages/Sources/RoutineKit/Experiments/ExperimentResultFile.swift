import DomainKit
import Foundation

/// The shareable summary of one finished or stopped experiment (`docs/PROTOCOL_FILES.md`, "Experiment result files").
///
/// It holds the design, the outcome fixed on day 1, the call with its label, the effect, the likely range, the
/// person's spread, the night counts and the two dates. It never holds a night's value, another metric (so no "also
/// moved"), an identifier, a time zone or anything else from the person's health data.
public struct ExperimentResultFile: Equatable, Sendable {
    public static let format = "loopr-experiment-result"
    public static let schemaVersion = 1
    /// 64 KB. A real file is under 2 KB.
    public static let maximumBytes = 65_536
    public static let maximumTextLength = 80

    public enum Call: String, CaseIterable, Sendable {
        /// The call has a label: Strong, Clear, Early or No change.
        case result
        /// Enough nights, but the range is wider than the spread.
        case notCalled
        /// An arm ended below the minimum nights.
        case notEnoughNights
        /// The nights before day 1 were too few to learn the spread.
        case cannotReport
    }

    public struct Nights: Equatable, Sendable {
        /// Scheduled nights up to the last one that counts.
        public let completed: Int
        public let onCounted: Int
        public let offCounted: Int
        /// Washout nights, nights the intervention was not done or not ticked, and nights with no reading.
        public let leftOut: Int

        public init(completed: Int, onCounted: Int, offCounted: Int, leftOut: Int) {
            self.completed = completed; self.onCounted = onCounted; self.offCounted = offCounted; self.leftOut = leftOut
        }
    }

    public struct Result: Equatable, Sendable {
        public let call: Call
        public let label: ExperimentLabel?
        /// Mean of the counted on nights minus mean of the counted off nights, in the outcome's unit.
        public let effect: Double?
        public let range: ClosedRange<Double>?
        public let spread: Double?
        public let rangeOutsideSpread: Bool
        public let favors: ExperimentFavor?

        public init(call: Call, label: ExperimentLabel?, effect: Double?, range: ClosedRange<Double>?, spread: Double?,
                    rangeOutsideSpread: Bool, favors: ExperimentFavor?) {
            self.call = call; self.label = label; self.effect = effect; self.range = range; self.spread = spread
            self.rangeOutsideSpread = rangeOutsideSpread; self.favors = favors
        }
    }

    public let title: String
    public let interventionName: String
    public let ruleKey: RuleKey
    public let design: ExperimentDesign
    public let washout: Int
    public let minimumNightsPerArm: Int
    public let plannedNights: Int
    public let outcome: ExperimentMetric
    /// `finished` or `stopped`. A running experiment has no result file.
    public let status: ExperimentStatus
    public let startDay: DayIdentity
    public let endDay: DayIdentity
    public let nights: Nights
    public let result: Result
    public let policyVersion: String

    public init(title: String, interventionName: String, ruleKey: RuleKey, design: ExperimentDesign, washout: Int,
                minimumNightsPerArm: Int, plannedNights: Int, outcome: ExperimentMetric, status: ExperimentStatus,
                startDay: DayIdentity, endDay: DayIdentity, nights: Nights, result: Result, policyVersion: String) {
        self.title = title; self.interventionName = interventionName; self.ruleKey = ruleKey; self.design = design
        self.washout = washout; self.minimumNightsPerArm = minimumNightsPerArm; self.plannedNights = plannedNights
        self.outcome = outcome; self.status = status; self.startDay = startDay; self.endDay = endDay
        self.nights = nights; self.result = result; self.policyVersion = policyVersion
    }

    /// The file for a finished or stopped experiment and its report. Numbers are rounded to two decimals.
    public static func make(experiment: Experiment, report: ExperimentReport) throws -> ExperimentResultFile {
        guard experiment.status != .running, let endDay = experiment.endDay else { throw ExperimentResultFileError.stillRunning }
        guard report.experimentID == experiment.id else { throw ExperimentResultFileError.reportMismatch }
        let start = experiment.start
        let call: Call
        switch report.state {
        case .result: call = .result
        case .notCalled: call = .notCalled
        case .notEnoughNights, .tooEarlyToSay: call = .notEnoughNights
        case .cannotReport: call = .cannotReport
        }
        let leftOut = report.on.exclusions.total + report.off.exclusions.total
        let file = ExperimentResultFile(
            title: start.title, interventionName: start.interventionName, ruleKey: start.ruleKey, design: start.design,
            washout: start.washout, minimumNightsPerArm: start.minimumNightsPerArm, plannedNights: start.plannedNights,
            outcome: start.outcome, status: experiment.status, startDay: start.startDay, endDay: endDay,
            nights: Nights(completed: report.nightsCompleted, onCounted: report.on.nights, offCounted: report.off.nights,
                           leftOut: leftOut),
            result: Result(call: call, label: report.label, effect: report.difference.map(rounded),
                           range: report.range.map { rounded($0.lowerBound)...rounded($0.upperBound) },
                           spread: report.spread.map(rounded), rangeOutsideSpread: report.rangeOutsideSpread,
                           favors: report.favors),
            policyVersion: report.policyVersion)
        try file.validate()
        return file
    }

    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: Checks

    func validate() throws {
        func text(_ value: String, _ path: String, maximum: Int = Self.maximumTextLength) throws {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, value.count <= maximum,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ExperimentResultFileError.badValue(path)
            }
        }
        try text(title, "title")
        try text(interventionName, "intervention")
        try text(ruleKey.rawValue, "ruleKey", maximum: 64)
        try text(outcome.key, "outcome.metric", maximum: 64)
        try text(outcome.title, "outcome.title")
        guard outcome.unit.count <= 16 else { throw ExperimentResultFileError.badValue("outcome.unit") }
        try text(policyVersion, "policyVersion", maximum: 40)

        guard minimumNightsPerArm >= ExperimentStart.smallestMinimumNightsPerArm else {
            throw ExperimentResultFileError.badValue("minimumNightsPerArm")
        }
        do {
            try ExperimentSchedule.validate(design: design, washout: washout, plannedNights: plannedNights,
                                            minimumNightsPerArm: minimumNightsPerArm)
        } catch {
            throw ExperimentResultFileError.badValue("design")
        }
        guard status != .running else { throw ExperimentResultFileError.badValue("status") }
        guard startDay.routineDayKey != nil else { throw ExperimentResultFileError.badValue("startDay") }
        guard endDay.routineDayKey != nil, let length = startDay.days(until: endDay), length >= 0, length < plannedNights else {
            throw ExperimentResultFileError.badValue("endDay")
        }
        guard nights.completed >= 0, nights.completed <= plannedNights else {
            throw ExperimentResultFileError.badValue("nights.completed")
        }
        guard nights.onCounted >= 0, nights.offCounted >= 0, nights.leftOut >= 0,
              nights.onCounted + nights.offCounted + nights.leftOut == nights.completed else {
            throw ExperimentResultFileError.badValue("nights")
        }

        let finite: (Double?) -> Bool = { $0.map(\.isFinite) ?? true }
        guard finite(result.effect) else { throw ExperimentResultFileError.badValue("result.effect") }
        if let range = result.range {
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { throw ExperimentResultFileError.badValue("result.range") }
        }
        if let spread = result.spread {
            guard spread.isFinite, spread >= 0 else { throw ExperimentResultFileError.badValue("result.spread") }
        }
        switch result.call {
        case .result:
            guard result.label != nil else { throw ExperimentResultFileError.missingField("result.label") }
            guard result.effect != nil else { throw ExperimentResultFileError.missingField("result.effect") }
            guard result.range != nil else { throw ExperimentResultFileError.missingField("result.range") }
            guard result.spread != nil else { throw ExperimentResultFileError.missingField("result.spread") }
        case .notCalled:
            guard result.label == nil else { throw ExperimentResultFileError.badValue("result.label") }
            guard result.range != nil else { throw ExperimentResultFileError.missingField("result.range") }
            guard result.spread != nil else { throw ExperimentResultFileError.missingField("result.spread") }
        case .notEnoughNights:
            guard result.label == nil else { throw ExperimentResultFileError.badValue("result.label") }
            guard result.range == nil else { throw ExperimentResultFileError.badValue("result.range") }
        case .cannotReport:
            guard result.label == nil else { throw ExperimentResultFileError.badValue("result.label") }
            guard result.range == nil, result.spread == nil else { throw ExperimentResultFileError.badValue("result.spread") }
        }
    }
}

public enum ExperimentResultFileError: Error, Equatable, LocalizedError, Sendable {
    case tooLarge(bytes: Int)
    case notResultFile
    case newerVersion(Int)
    case unknownVersion(Int)
    case missingField(String)
    case badValue(String)
    case stillRunning
    case reportMismatch

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "This file is larger than 64 KB, so Loopr will not open it."
        case .notResultFile: "This file is not a Loopr experiment result."
        case .newerVersion: "This file needs a newer version of Loopr."
        case .unknownVersion: "This file uses a format version Loopr does not know."
        case .missingField(let path): "The file is missing \"\(path)\"."
        case .badValue(let path): "The value for \"\(path)\" is not one Loopr can use."
        case .stillRunning: "This experiment is still running, so it has no result file yet."
        case .reportMismatch: "This result belongs to a different experiment."
        }
    }
}

/// Writes and reads result files. `decode` has no side effects: it returns a checked file or throws, and it never
/// touches a store.
public enum ExperimentResultFileCodec {
    /// The file as JSON. Keys are sorted, so the same result always gives the same bytes.
    public static func encode(_ file: ExperimentResultFile) throws -> Data {
        try file.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(FileDTO(file))
    }

    /// Checks a file in the order `docs/PROTOCOL_FILES.md` lists and returns it, or throws the first refusal.
    public static func decode(_ data: Data) throws -> ExperimentResultFile {
        guard data.count <= ExperimentResultFile.maximumBytes else {
            throw ExperimentResultFileError.tooLarge(bytes: data.count)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            throw ExperimentResultFileError.notResultFile
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.format == ExperimentResultFile.format else {
            throw ExperimentResultFileError.notResultFile
        }
        guard let version = header.schemaVersion else { throw ExperimentResultFileError.missingField("schemaVersion") }
        guard version >= 1 else { throw ExperimentResultFileError.unknownVersion(version) }
        guard version == ExperimentResultFile.schemaVersion else { throw ExperimentResultFileError.newerVersion(version) }

        let dto: FileDTO
        do {
            dto = try decoder.decode(FileDTO.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw ExperimentResultFileError.missingField(path(context.codingPath + [key]))
        } catch let DecodingError.valueNotFound(_, context) {
            throw ExperimentResultFileError.missingField(path(context.codingPath))
        } catch let DecodingError.typeMismatch(_, context) {
            throw ExperimentResultFileError.badValue(path(context.codingPath))
        } catch let DecodingError.dataCorrupted(context) {
            throw ExperimentResultFileError.badValue(path(context.codingPath))
        } catch {
            throw ExperimentResultFileError.notResultFile
        }
        let file = try dto.file()
        try file.validate()
        return file
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map(\.stringValue).joined(separator: ".")
    }

    // MARK: Shape

    private struct Header: Decodable {
        let format: String?
        let schemaVersion: Int?
    }

    private struct FileDTO: Codable {
        struct Design: Codable { let kind: String; let length: Int? }
        struct Outcome: Codable { let metric: String; let title: String; let unit: String; let betterWhen: String }
        struct Nights: Codable { let completed: Int; let onCounted: Int; let offCounted: Int; let leftOut: Int }
        struct Range: Codable { let low: Double; let high: Double }
        struct Result: Codable {
            let call: String
            let label: String?
            let effect: Double?
            let range: Range?
            let spread: Double?
            let rangeOutsideSpread: Bool
            let favors: String?
        }

        let format: String
        let schemaVersion: Int
        let title: String
        let intervention: String
        let ruleKey: String
        let design: Design
        let washout: Int
        let minimumNightsPerArm: Int
        let plannedNights: Int
        let outcome: Outcome
        let status: String
        let startDay: String
        let endDay: String
        let nights: Nights
        let result: Result
        let policyVersion: String

        init(_ file: ExperimentResultFile) {
            format = ExperimentResultFile.format
            schemaVersion = ExperimentResultFile.schemaVersion
            title = file.title
            intervention = file.interventionName
            ruleKey = file.ruleKey.rawValue
            design = Design(kind: file.design.kind, length: file.design.length)
            washout = file.washout
            minimumNightsPerArm = file.minimumNightsPerArm
            plannedNights = file.plannedNights
            outcome = Outcome(metric: file.outcome.key, title: file.outcome.title, unit: file.outcome.unit,
                              betterWhen: file.outcome.benefit.rawValue)
            status = file.status.rawValue
            startDay = file.startDay.routineDayKey ?? ""
            endDay = file.endDay.routineDayKey ?? ""
            nights = Nights(completed: file.nights.completed, onCounted: file.nights.onCounted,
                            offCounted: file.nights.offCounted, leftOut: file.nights.leftOut)
            result = Result(call: file.result.call.rawValue, label: file.result.label?.rawValue, effect: file.result.effect,
                            range: file.result.range.map { Range(low: $0.lowerBound, high: $0.upperBound) },
                            spread: file.result.spread, rangeOutsideSpread: file.result.rangeOutsideSpread,
                            favors: file.result.favors?.rawValue)
            policyVersion = file.policyVersion
        }

        func file() throws -> ExperimentResultFile {
            guard let design = ExperimentDesign(kind: self.design.kind, length: self.design.length) else {
                throw ExperimentResultFileError.badValue("design")
            }
            guard let benefit = ExperimentBenefit(rawValue: outcome.betterWhen) else {
                throw ExperimentResultFileError.badValue("outcome.betterWhen")
            }
            guard let status = ExperimentStatus(rawValue: self.status), status != .running else {
                throw ExperimentResultFileError.badValue("status")
            }
            guard let start = DayIdentity(routineDayKey: startDay), start.routineDayKey == startDay else {
                throw ExperimentResultFileError.badValue("startDay")
            }
            guard let end = DayIdentity(routineDayKey: endDay), end.routineDayKey == endDay else {
                throw ExperimentResultFileError.badValue("endDay")
            }
            guard let call = ExperimentResultFile.Call(rawValue: result.call) else {
                throw ExperimentResultFileError.badValue("result.call")
            }
            var label: ExperimentLabel?
            if let raw = result.label {
                guard let parsed = ExperimentLabel(rawValue: raw) else { throw ExperimentResultFileError.badValue("result.label") }
                label = parsed
            }
            var favors: ExperimentFavor?
            if let raw = result.favors {
                guard let parsed = ExperimentFavor(rawValue: raw) else { throw ExperimentResultFileError.badValue("result.favors") }
                favors = parsed
            }
            var range: ClosedRange<Double>?
            if let given = result.range {
                guard given.low.isFinite, given.high.isFinite, given.low <= given.high else {
                    throw ExperimentResultFileError.badValue("result.range")
                }
                range = given.low...given.high
            }
            return ExperimentResultFile(
                title: title, interventionName: intervention, ruleKey: RuleKey(rawValue: ruleKey), design: design,
                washout: washout, minimumNightsPerArm: minimumNightsPerArm, plannedNights: plannedNights,
                outcome: ExperimentMetric(key: outcome.metric, title: outcome.title, unit: outcome.unit, benefit: benefit),
                status: status, startDay: start, endDay: end,
                nights: ExperimentResultFile.Nights(completed: nights.completed, onCounted: nights.onCounted,
                                                    offCounted: nights.offCounted, leftOut: nights.leftOut),
                result: ExperimentResultFile.Result(call: call, label: label, effect: result.effect, range: range,
                                                    spread: result.spread, rangeOutsideSpread: result.rangeOutsideSpread,
                                                    favors: favors),
                policyVersion: policyVersion)
        }
    }
}
