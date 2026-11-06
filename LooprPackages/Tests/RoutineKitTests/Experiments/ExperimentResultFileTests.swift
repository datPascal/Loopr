import DomainKit
import Foundation
import Testing
@testable import RoutineKit

/// LV-07.3: the experiment result file round-trips, holds no night values, and the decoder refuses anything else
/// without side effects (`docs/PROTOCOL_FILES.md`, "Experiment result files").
struct ExperimentResultFileTests {
    private func finished(on: [Double] = ExpFixtures.clearOn, off: [Double] = ExpFixtures.clearOff,
                          status: ExperimentStatus = .finished, endOffset: Int = 13) throws -> (Experiment, ExperimentReport) {
        let experiment = try ExpFixtures.experiment(status: status, endDay: ExpFixtures.night(endOffset))
        let nights = try ExpFixtures.nights(for: experiment, on: on, off: off)
        return (experiment, ExpFixtures.report(experiment, nights: nights, lastNight: ExpFixtures.night(13)))
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func encoded() throws -> (ExperimentResultFile, Data) {
        let (experiment, report) = try finished()
        let file = try ExperimentResultFile.make(experiment: experiment, report: report)
        return (file, try ExperimentResultFileCodec.encode(file))
    }

    @Test func aFinishedResultRoundTripsWithTheSameBytes() throws {
        let (experiment, report) = try finished()
        let file = try ExperimentResultFile.make(experiment: experiment, report: report)
        #expect(file.result.call == .result)
        #expect(file.result.label == report.label)
        #expect(file.result.effect == ExperimentResultFile.rounded(report.difference ?? .nan))
        #expect(file.nights == ExperimentResultFile.Nights(completed: 14, onCounted: 7, offCounted: 7, leftOut: 0))
        #expect(file.startDay == ExpFixtures.startDay && file.endDay == ExpFixtures.night(13))
        #expect(file.outcome == .deepSleep && file.design == .alternatingDays)

        let bytes = try ExperimentResultFileCodec.encode(file)
        #expect(try ExperimentResultFileCodec.decode(bytes) == file)
        #expect(try ExperimentResultFileCodec.encode(file) == bytes, "The same result always gives the same bytes")
    }

    @Test func aStoppedResultRoundTripsAsStopped() throws {
        let (experiment, report) = try finished(status: .stopped, endOffset: 5)
        #expect(experiment.stoppedEarly)
        let file = try ExperimentResultFile.make(experiment: experiment, report: report)
        #expect(file.status == .stopped && file.endDay == ExpFixtures.night(5))
        #expect(file.nights.completed == 6)
        #expect(try ExperimentResultFileCodec.decode(try ExperimentResultFileCodec.encode(file)) == file)
    }

    @Test func theFileHoldsNoNightValuesAndNoOtherHealthData() throws {
        let (experiment, report) = try finished()
        let bytes = try ExperimentResultFileCodec.encode(try ExperimentResultFile.make(experiment: experiment, report: report))
        let object = try json(bytes)
        #expect(Set(object.keys) == ["format", "schemaVersion", "title", "intervention", "ruleKey", "design", "washout",
                                     "minimumNightsPerArm", "plannedNights", "outcome", "status", "startDay", "endDay",
                                     "nights", "result", "policyVersion"])
        let nights = try #require(object["nights"] as? [String: Any])
        #expect(Set(nights.keys) == ["completed", "onCounted", "offCounted", "leftOut"])
        let result = try #require(object["result"] as? [String: Any])
        #expect(Set(result.keys).isSubset(of: ["call", "label", "effect", "range", "spread", "rangeOutsideSpread", "favors"]))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(experiment.id.rawValue.uuidString), "No identifier")
        #expect(!text.contains("Europe/Berlin"), "No time zone")
        // Every night value is between 58 and 82; none of them may appear as a number in the file.
        for value in ExpFixtures.clearOn + ExpFixtures.clearOff {
            #expect(!text.contains(": \(Int(value))\n") && !text.contains(": \(Int(value)),"), "Night value \(value)")
        }
    }

    @Test func aRunningExperimentHasNoFile() throws {
        let experiment = try ExpFixtures.experiment()
        let report = ExpFixtures.report(experiment, nights: try ExpFixtures.nights(for: experiment, on: ExpFixtures.clearOn,
                                                                                   off: ExpFixtures.clearOff))
        #expect(throws: ExperimentResultFileError.stillRunning) {
            try ExperimentResultFile.make(experiment: experiment, report: report)
        }
    }

    @Test func theDecoderRefusesEverythingElse() throws {
        let (_, bytes) = try encoded()
        let good = try json(bytes)

        #expect(throws: ExperimentResultFileError.tooLarge(bytes: ExperimentResultFile.maximumBytes + 1)) {
            try ExperimentResultFileCodec.decode(Data(repeating: 0x20, count: ExperimentResultFile.maximumBytes + 1))
        }
        #expect(throws: ExperimentResultFileError.notResultFile) { try ExperimentResultFileCodec.decode(Data("nope".utf8)) }
        #expect(throws: ExperimentResultFileError.notResultFile) { try ExperimentResultFileCodec.decode(Data("[1, 2]".utf8)) }

        func refusal(_ change: (inout [String: Any]) -> Void) throws -> ExperimentResultFileError? {
            var object = good
            change(&object)
            do {
                _ = try ExperimentResultFileCodec.decode(try data(object))
                return nil
            } catch let error as ExperimentResultFileError {
                return error
            }
        }

        #expect(try refusal { $0["format"] = "loopr-protocol" } == .notResultFile)
        #expect(try refusal { $0["schemaVersion"] = 2 } == .newerVersion(2))
        #expect(try refusal { $0["schemaVersion"] = 0 } == .unknownVersion(0))
        #expect(try refusal { $0["schemaVersion"] = nil } == .missingField("schemaVersion"))
        #expect(try refusal { $0["title"] = nil } == .missingField("title"))
        #expect(try refusal { $0["washout"] = "0" } == .badValue("washout"))
        #expect(try refusal { $0["title"] = "  " } == .badValue("title"))
        #expect(try refusal { $0["status"] = "running" } == .badValue("status"))
        #expect(try refusal { $0["startDay"] = "2026-02-30" } == .badValue("startDay"))
        #expect(try refusal { $0["endDay"] = "2026-09-01" } == .badValue("endDay"))
        #expect(try refusal { $0["design"] = ["kind": "blocks"] } == .badValue("design"))
        #expect(try refusal { $0["minimumNightsPerArm"] = 9 } == .badValue("design"))
        #expect(try refusal { object in
            var nights = object["nights"] as? [String: Any] ?? [:]
            nights["onCounted"] = 8
            object["nights"] = nights
        } == .badValue("nights"))
        #expect(try refusal { object in
            var result = object["result"] as? [String: Any] ?? [:]
            result["label"] = "huge"
            object["result"] = result
        } == .badValue("result.label"))
        #expect(try refusal { object in
            var result = object["result"] as? [String: Any] ?? [:]
            result["range"] = nil
            object["result"] = result
        } == .missingField("result.range"))
        #expect(try refusal { object in
            var result = object["result"] as? [String: Any] ?? [:]
            result["call"] = "notEnoughNights"
            object["result"] = result
        } == .badValue("result.label"), "A label without a result call is refused")
        #expect(try refusal { object in
            var result = object["result"] as? [String: Any] ?? [:]
            result["range"] = ["low": 9, "high": 2]
            object["result"] = result
        } == .badValue("result.range"))

        // A field the reader does not know is skipped.
        var extra = good
        extra["mood"] = "fine"
        #expect(try ExperimentResultFileCodec.decode(try data(extra)) == ExperimentResultFileCodec.decode(bytes))
    }

    @Test func everyRefusalHasAPlainMessage() {
        let errors: [ExperimentResultFileError] = [.tooLarge(bytes: 1), .notResultFile, .newerVersion(2), .unknownVersion(0),
                                                   .missingField("title"), .badValue("nights"), .stillRunning, .reportMismatch]
        for error in errors {
            let message = error.errorDescription ?? ""
            #expect(!message.isEmpty && !message.contains("!") && !message.contains("\u{2014}"), "\(error)")
        }
        #expect(ExperimentResultFileError.missingField("result.range").errorDescription == "The file is missing \"result.range\".")
    }
}
