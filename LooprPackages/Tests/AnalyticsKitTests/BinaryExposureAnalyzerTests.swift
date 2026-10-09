import AnalyticsKit
import XCTest

final class BinaryExposureAnalyzerTests: XCTestCase {
    private let policy = BinaryExposurePolicy(
        baselineWindowDays: 28,
        minimumBaselineValues: 3,
        ridgeLambda: 1,
        bootstrapReplicates: 200,
        blockLength: 3
    )

    func testRawAndAdjustedEffectsAreDeterministic() throws {
        let baseline = (0..<40).map {
            BinaryExposureBaselineValue(dayOrdinal: $0, value: 50 + Double($0 % 4))
        }
        let rows = (4..<40).map { day in
            let exposed = day.isMultiple(of: 2)
            return BinaryExposureRow(
                dayOrdinal: day,
                outcome: 50 + Double(day % 4) + (exposed ? 5 : 0),
                exposure: exposed,
                weekday: day % 7,
                priorDayStrain: Double(day % 10),
                nuisanceExposures: [day.isMultiple(of: 3) ? 1 : 0]
            )
        }
        let first = try BinaryExposureAnalyzer.analyze(
            rows: rows, baselineValues: baseline, policy: policy, seed: 42
        )
        let second = try BinaryExposureAnalyzer.analyze(
            rows: rows, baselineValues: baseline, policy: policy, seed: 42
        )
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.rawDifference, 3)
        XCTAssertGreaterThan(first.adjustedDifference ?? 0, 3)
        XCTAssertEqual(first.adjustedRowCount, rows.count)
    }

    func testOverlapAndHolmAdjustment() {
        let overlap = BinaryExposureAnalyzer.phiAndDiscordance(
            target: [true, true, false, false],
            other: [true, true, false, false]
        )
        XCTAssertEqual(overlap.phi, 1)
        XCTAssertEqual(overlap.targetYesOtherNo, 0)
        XCTAssertEqual(overlap.targetNoOtherYes, 0)
        XCTAssertEqual(
            BinaryExposureAnalyzer.holmAdjusted([0.01, 0.04, nil, 0.03]),
            [0.03, 0.06, nil, 0.06]
        )
    }
}
