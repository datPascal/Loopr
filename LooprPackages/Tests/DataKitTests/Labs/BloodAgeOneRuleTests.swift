import AnalyticsKit
@testable import DataKit
import Foundation
import XCTest

/// LV-08b integration: the Data root's ruler (`DataBloodAgeBuilder`) and the blood tests screens (`LabBloodAgeSource`)
/// read one blood age rule. On the same stored reports they give the same value, the same report and the same absent
/// reason.
final class BloodAgeOneRuleTests: XCTestCase {
    private typealias S = DataOverviewTestSupport

    private func stored(_ draws: [DataLabDraw]) -> (reports: [LabReport], values: [LabValue]) {
        (draws.map(\.report), draws.flatMap(\.values))
    }

    /// Both readers on the same reports, with the ruler's own `make` as the third.
    private func both(_ draws: [DataLabDraw], birthYear: Int?, file: StaticString = #filePath, line: UInt = #line) -> DataBloodAge {
        let (reports, values) = stored(draws)
        let rulerSide = DataBloodAgeBuilder.make(draws: draws, birthYear: birthYear)
        let labsSide = LabBloodAgeSource.bloodAge(reports: reports, values: values, birthYear: birthYear)
        XCTAssertEqual(labsSide, rulerSide, file: file, line: line)
        XCTAssertEqual(labsSide.absence, rulerSide.absence, file: file, line: line)
        XCTAssertEqual(LabBloodAgeSource.reportID(reports: reports, values: values, birthYear: birthYear),
                       rulerSide.reading?.report.id, file: file, line: line)
        let ruler = DataAgeRuler.make(birthYear: birthYear, draws: draws, vo2Max: .readings([]), referenceGroup: nil,
                                      now: S.date(2026, 10, 25), calendar: S.calendar)
        XCTAssertEqual(ruler.blood, rulerSide, file: file, line: line)
        return labsSide
    }

    func testTwoCompleteReportsGiveTheNewestOneAndTheSameValue() throws {
        let older = S.completeDraw(at: S.date(2026, 3, 2))
        let newer = S.completeDraw(at: S.date(2026, 9, 12))
        let blood = both([older, newer], birthYear: 1988)
        let reading = try XCTUnwrap(blood.reading)
        XCTAssertEqual(reading.report.id, newer.report.id)
        XCTAssertEqual(reading.estimate.phenotypicAgeYears,
                       try XCTUnwrap(DataBloodAgeBuilder.make(draws: [newer], birthYear: 1988).reading).estimate.phenotypicAgeYears,
                       accuracy: 1e-12)
    }

    func testANewerReportWithAMissingMarkerIsSkippedByBoth() throws {
        let complete = S.completeDraw(at: S.date(2026, 3, 2))
        let newer = S.report(at: S.date(2026, 9, 12))
        let partial = DataLabDraw(report: newer, values: [S.value(newer, .apoB, "78", "mg/dL"), S.value(newer, .albumin, "46", "g/L")])
        let blood = both([partial, complete], birthYear: 1988)
        XCTAssertEqual(try XCTUnwrap(blood.reading).report.id, complete.report.id)
    }

    func testEveryAbsentReasonIsTheSameOnBothSides() {
        XCTAssertEqual(both([], birthYear: 1988).absence, .noReport)

        let report = S.report(at: S.drawn)
        let missing = DataLabDraw(report: report, values: Array(S.phenoAgeValues(report).dropFirst(2)))
        XCTAssertEqual(both([missing], birthYear: 1988).absence, .missingMarkers([.albumin, .creatinine], report: report))

        // Nothing is complete: the reason names the newest report's gaps, not an older report's.
        let older = S.report(at: S.date(2026, 3, 2))
        let olderDraw = DataLabDraw(report: older, values: [S.value(older, .albumin, "46", "g/L")])
        XCTAssertEqual(both([olderDraw, missing], birthYear: 1988).absence, .missingMarkers([.albumin, .creatinine], report: report))

        let complete = S.completeDraw()
        XCTAssertEqual(both([complete], birthYear: nil).absence, .noBirthYear)
        // A birth year after the draw gives no age at the draw, with the reason and not a silent nil.
        XCTAssertEqual(both([complete], birthYear: 2027).absence, .notCalculated(.invalidChronologicalAge, report: complete.report))
        let outOfRange = S.completeDraw(albumin: "500")
        XCTAssertEqual(both([outOfRange], birthYear: 1988).absence,
                       .notCalculated(.outsideReferenceRange(.albumin), report: outOfRange.report))
    }

    func testAMissingMarkerLeavesBloodAgeAbsentNeverFilledIn() {
        let report = S.report(at: S.drawn)
        let values = S.phenoAgeValues(report).filter { $0.subject.markerKey != .crp }
        let blood = both([DataLabDraw(report: report, values: values)], birthYear: 1988)
        XCTAssertNil(blood.reading)
        XCTAssertEqual(blood.absence, .missingMarkers([.crp], report: report))
    }

    func testTheEngineIsCalledOnceWithTheSameAgeFromEitherSide() throws {
        let draw = S.completeDraw()
        let recorderA = PhenoAgeCallRecorder(), recorderB = PhenoAgeCallRecorder()
        _ = DataBloodAgeBuilder.make(draws: [draw], birthYear: 1988, calculate: recorderA.calculate)
        _ = LabBloodAgeSource.bloodAge(reports: [draw.report], values: draw.values, birthYear: 1988, calculate: recorderB.calculate)
        XCTAssertEqual(recorderA.calls.count, 1)
        XCTAssertEqual(recorderB.calls.count, 1)
        XCTAssertEqual(try XCTUnwrap(recorderA.calls.first).chronologicalAgeYears,
                       try XCTUnwrap(recorderB.calls.first).chronologicalAgeYears, accuracy: 1e-12)
    }
}
