import Foundation
import XCTest
@testable import AnalyticsKit

final class ParityComparatorTests: XCTestCase {
    private let manifest = ParityToleranceManifest(
        rules: [
            "exact": .init(category: "exact"),
            "canonical-rounded": .init(category: "canonical-rounded", decimals: 0),
            "float-primitive": .init(category: "float-primitive", absolute: 1e-9),
            "normalized-score": .init(category: "normalized-score", absolute: 1e-6),
            "spectral-iterative": .init(category: "spectral-iterative", absolute: 1e-8, relative: 1e-5, absoluteFloor: 1e-8)
        ],
        fields: [
            "exact": "exact",
            "rounded": "canonical-rounded",
            "primitive": "float-primitive",
            "score": "normalized-score",
            "spectrum": "spectral-iterative"
        ]
    )

    func test_eachToleranceCategoryPassesAndFailsAtItsBoundary() throws {
        let expected = #"{"exact":7,"rounded":10.49,"primitive":1.0,"score":0.5,"spectrum":100.0}"#.data(using: .utf8)!
        let pass = #"{"exact":7,"rounded":10.40,"primitive":1.0000000005,"score":0.5000005,"spectrum":100.0005}"#.data(using: .utf8)!
        let fail = #"{"exact":8,"rounded":11.51,"primitive":1.00000001,"score":0.500002,"spectrum":100.01}"#.data(using: .utf8)!

        let passReport = try AnalyticsParityComparator.compare(expected: expected, actual: pass, manifest: manifest)
        XCTAssertTrue(passReport.passed, passReport.humanReadable)
        let failReport = try AnalyticsParityComparator.compare(expected: expected, actual: fail, manifest: manifest)
        XCTAssertFalse(failReport.passed)
        XCTAssertEqual(failReport.differences.filter { !$0.passed }.count, 5)
    }

    func test_presenceAndAbsenceMismatchFailsRegardlessOfNumericCategory() throws {
        let expected = #"{"value":1.0,"present":true}"#.data(using: .utf8)!
        let actual = #"{"value":1.0,"present":false}"#.data(using: .utf8)!
        let report = try AnalyticsParityComparator.compare(expected: expected, actual: actual, manifest: manifest)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.differences.contains { $0.field == "present" })
    }

    func testMissingFieldIsAComparatorFailureAndUsesFailClosedExactDefault() throws {
        let expected = #"{"value":{"required":1.0,"label":"present"}}"#.data(using: .utf8)!
        let actual = #"{"value":{"label":"present"}}"#.data(using: .utf8)!
        let report = try AnalyticsParityComparator.compare(expected: expected, actual: actual, manifest: manifest)
        XCTAssertFalse(report.passed)
        let missing = try XCTUnwrap(report.differences.first { $0.field == "value.required" })
        XCTAssertEqual(missing.category, "exact")
        XCTAssertEqual(missing.expected, "1")
        XCTAssertEqual(missing.actual, "<missing>")
        XCTAssertFalse(missing.passed)
    }
}

final class ParityDeterminismTests: XCTestCase {
    func test_runnerProducesByteIdenticalOutputForRepeatedFixture() throws {
        let fixture = #"{"metric":"strainScoreMetric","trimp":335}"#.data(using: .utf8)!
        let first = try AnalyticsParityRunner.run(inputData: fixture)
        let second = try AnalyticsParityRunner.run(inputData: fixture)
        XCTAssertEqual(first, second)
    }

    func test_sleepSegmentationRejectsUndeclaredOrUnresolvableTimezone() throws {
        let missing = #"{"metric":"sleepSegmentation","acceleration":[],"heart_rate":[],"rr":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try AnalyticsParityRunner.run(inputData: missing)) { error in
            XCTAssertTrue(String(describing: error).contains("time_zone_identifier"), String(describing: error))
        }

        let invalid = #"{"metric":"sleepSegmentation","time_zone_identifier":"Mars/Olympus_Mons","acceleration":[],"heart_rate":[],"rr":[]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try AnalyticsParityRunner.run(inputData: invalid)) { error in
            XCTAssertTrue(String(describing: error).contains("time_zone_identifier"), String(describing: error))
        }
    }
}
