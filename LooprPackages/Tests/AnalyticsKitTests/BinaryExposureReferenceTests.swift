import AnalyticsKit
import Foundation
import XCTest

final class BinaryExposureReferenceTests: XCTestCase {
    /// Recorded from 11e7697 before changing matrix storage. Exact comparisons
    /// protect estimates, confidence bounds and p-values, not just their signs.
    func testOptimizedKernelMatchesAllRecordedBootstrapResultsExactly() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "binary-exposure-reference", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.count, 6)
        for fixture in fixtures {
            let result = try BinaryExposureAnalyzer.analyze(rows: fixture.rows.map(\.value),
                baselineValues: fixture.baseline.map(\.baseline), policy: Self.policy, seed: fixture.seed)
            let expected = fixture.expected
            XCTAssertEqual(result.yesMean, expected.yesMean, fixture.name)
            XCTAssertEqual(result.noMean, expected.noMean, fixture.name)
            XCTAssertEqual(result.rawDifference, expected.rawDifference, fixture.name)
            XCTAssertEqual(result.adjustedDifference, expected.adjustedDifference, fixture.name)
            XCTAssertEqual(result.intervalLower, expected.intervalLower, fixture.name)
            XCTAssertEqual(result.intervalUpper, expected.intervalUpper, fixture.name)
            XCTAssertEqual(result.twoSidedPValue, expected.twoSidedPValue, fixture.name)
            XCTAssertEqual(result.adjustedRowCount, expected.adjustedRowCount, fixture.name)
        }
    }

    func testInvalidShapesAndInsufficientAdjustedRowsDoNotEnterTheKernel() throws {
        XCTAssertThrowsError(try BinaryExposureAnalyzer.analyze(rows: [], baselineValues: [], policy: Self.policy, seed: 0)) {
            XCTAssertEqual($0 as? BinaryExposureError, .emptyInput)
        }
        let no = BinaryExposureRow(dayOrdinal: 0, outcome: 10, exposure: false, weekday: 0, priorDayStrain: nil)
        let yes = BinaryExposureRow(dayOrdinal: 4, outcome: 12, exposure: true, weekday: 4, priorDayStrain: nil)
        let mismatch = BinaryExposureRow(dayOrdinal: 4, outcome: 12, exposure: true, weekday: 4,
            priorDayStrain: nil, nuisanceExposures: [1])
        XCTAssertThrowsError(try BinaryExposureAnalyzer.analyze(rows: [no, mismatch], baselineValues: [], policy: Self.policy, seed: 0)) {
            XCTAssertEqual($0 as? BinaryExposureError, .inconsistentNuisanceColumns)
        }
        let baseline = (0..<3).map { BinaryExposureBaselineValue(dayOrdinal: $0, value: 10) }
        let result = try BinaryExposureAnalyzer.analyze(rows: [no, yes], baselineValues: baseline, policy: Self.policy, seed: 0)
        XCTAssertEqual(result.adjustedRowCount, 1)
        XCTAssertNil(result.adjustedDifference)
        XCTAssertNil(result.intervalLower)
    }

    private static let policy = BinaryExposurePolicy(baselineWindowDays: 28, minimumBaselineValues: 3,
        ridgeLambda: 1, bootstrapReplicates: 2000, blockLength: 3)

    private struct Reference: Decodable {
        let name: String
        let seed: UInt64
        let rows: [Row]
        let baseline: [Baseline]
        let expected: Expected
    }
    private struct Row: Decodable {
        let dayOrdinal: Int; let outcome: Double; let exposure: Bool; let weekday: Int
        let priorDayStrain: Double?; let nuisanceExposures: [Double]
        var value: BinaryExposureRow {
            .init(dayOrdinal: dayOrdinal, outcome: outcome, exposure: exposure, weekday: weekday,
                  priorDayStrain: priorDayStrain, nuisanceExposures: nuisanceExposures)
        }
    }
    private struct Baseline: Decodable {
        let dayOrdinal: Int; let value: Double
        enum CodingKeys: String, CodingKey { case dayOrdinal, value }
        // Keep the JSON field named value while exposing a typed baseline.
        var baseline: BinaryExposureBaselineValue { .init(dayOrdinal: dayOrdinal, value: value) }
    }
    private struct Expected: Decodable {
        let yesMean: Double; let noMean: Double; let rawDifference: Double
        let adjustedDifference: Double?; let intervalLower: Double?; let intervalUpper: Double?
        let twoSidedPValue: Double?; let adjustedRowCount: Int
    }
}
