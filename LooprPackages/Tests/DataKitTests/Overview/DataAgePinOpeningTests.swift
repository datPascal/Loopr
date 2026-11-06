import AnalyticsKit
@testable import DataKit
import DesignSystem
import Foundation
import XCTest

/// LV-08b integration: a pin on the age ruler opens its real method page and passes the pin's value, and PhenoAge's
/// terms for the waterfall. Real age opens Profile.
final class DataAgePinOpeningTests: XCTestCase {
    private typealias S = DataOverviewTestSupport

    private let now = S.drawn.addingTimeInterval(43 * 86_400)

    private func ruler(draws: [DataLabDraw], vo2: Bool = true, birthYear: Int? = 1988) -> DataAgeRuler {
        DataAgeRuler.make(birthYear: birthYear, draws: draws, vo2Max: .readings(vo2 ? S.vo2Readings(now: now) : []),
                          referenceGroup: .male, now: now, calendar: S.calendar)
    }

    /// ICP R2-UPG-18: an empty ruler drew three blank pin lanes, about 90 pt, under "No age yet".
    func testTheRulerIsOnlyAsTallAsTheLanesItUses() {
        XCTAssertEqual(DataAgeRulerView.baseline(lanes: 0), 6)
        XCTAssertEqual(DataAgeRulerView.baseline(lanes: 1), 40)
        XCTAssertEqual(DataAgeRulerView.baseline(lanes: DataAgePinKind.allCases.count), DataAgeRulerView.fullBaseline)
        XCTAssertEqual(ruler(draws: [], vo2: false, birthYear: nil).placements.count, 0)
    }

    func testTheBloodPinOpensThePhenoAgePageWithItsValueAndWaterfall() throws {
        let ruler = ruler(draws: [S.completeDraw()])
        let estimate = try XCTUnwrap(ruler.blood.reading).estimate
        guard case .method(let id, let value?) = ruler.opening(for: .blood) else { return XCTFail("expected the PhenoAge page with a value") }
        XCTAssertEqual(id, .phenoAge)
        XCTAssertEqual(value.value, estimate.phenotypicAgeYears, accuracy: 1e-12)
        XCTAssertEqual(value.value, try XCTUnwrap(ruler.state(.blood).pin).years, accuracy: 1e-12)
        XCTAssertEqual(value.fractionDigits, 1)
        XCTAssertEqual(value.qualifier, "Riverside Lab")
        let waterfall = try XCTUnwrap(value.waterfall)
        // The average person at this age, then the nine markers against the NHANES IV averages, adding up to the value.
        XCTAssertEqual(waterfall.model.steps.count, 10)
        XCTAssertEqual(waterfall.model.end, estimate.phenotypicAgeYears, accuracy: 1e-9)
    }

    /// ICP R1-LAB-9: the Inputs card shows the person's own values, one source each, and the draw date.
    func testTheBloodPinsPageListsTheValuesItUsedWithTheirSourceAndDay() throws {
        let draw = S.completeDraw()
        guard case .method(_, let value?) = ruler(draws: [draw]).opening(for: .blood) else { return XCTFail("expected a value") }
        let inputs = try XCTUnwrap(value.inputs)
        XCTAssertEqual(inputs.count, PhenoAge.inputMarkers.count + 1)
        let day = DataText.day(draw.report.collectedAt, timeZoneIdentifier: draw.report.timeZoneIdentifier)
        let albumin = try XCTUnwrap(inputs.first { $0.name == "Albumin" })
        XCTAssertEqual(albumin.value, "46 g/L")
        XCTAssertEqual(albumin.provenance, .lab(name: "Riverside Lab"))
        XCTAssertEqual(albumin.note, "typed in, \(day)")
        // A converted unit says what the report gave and what the formula used.
        let crp = try XCTUnwrap(inputs.first { $0.name == LabMarkerKey.crp.marker.displayName })
        XCTAssertTrue(crp.value.hasPrefix("0.6 mg/L, used as 0.06 mg/dL"), crp.value)
        let age = try XCTUnwrap(inputs.last)
        XCTAssertEqual(age.name, "Age at the blood draw")
        XCTAssertNil(age.provenance)
        XCTAssertEqual(age.note, "From your birth year")
    }

    func testTheCardioPinOpensTheCardioAgePageWithItsValue() throws {
        let ruler = ruler(draws: [])
        let reading = try XCTUnwrap(ruler.cardio.reading)
        guard case .method(let id, let value?) = ruler.opening(for: .cardio) else { return XCTFail("expected the Cardio age page with a value") }
        XCTAssertEqual(id, .cardioAge)
        XCTAssertEqual(value.value, reading.years, accuracy: 1e-12)
        XCTAssertEqual(value.provenance, .appleHealth(source: "Apple Watch"))
        XCTAssertEqual(value.qualifier, "42-day median")
        XCTAssertNil(value.waterfall)
    }

    func testAPinThatIsNotOnTheRulerOpensWhereItsInputIsAdded() {
        let empty = ruler(draws: [], vo2: false)
        // No report with the nine values: the blood tests list, where one is added (ICP R1-LAB-7).
        XCTAssertEqual(empty.opening(for: .blood), .bloodTests)
        let report = S.report(at: S.drawn)
        let partial = DataLabDraw(report: report, values: Array(S.phenoAgeValues(report).dropFirst(2)))
        XCTAssertEqual(ruler(draws: [partial]).opening(for: .blood), .bloodTests)
        // No birth year: Profile.
        XCTAssertEqual(ruler(draws: [S.completeDraw()], birthYear: nil).opening(for: .blood), .profile)
        // A report the formula cannot take: the method page explains the limits.
        XCTAssertEqual(ruler(draws: [S.completeDraw(albumin: "500")]).opening(for: .blood), .method(.phenoAge, nil))
        // Too few VO₂max readings: how to get them. With the read off, no reading can arrive, so the method page.
        XCTAssertEqual(empty.opening(for: .cardio), .vo2MaxGuide)
        let switchedOff = DataAgeRuler.make(birthYear: 1988, draws: [], vo2Max: .switchedOff, referenceGroup: .male,
                                            now: now, calendar: S.calendar)
        XCTAssertEqual(switchedOff.opening(for: .cardio), .method(.cardioAge, nil))
    }

    func testRealAgeOpensProfileWhereTheBirthYearLives() {
        XCTAssertEqual(ruler(draws: []).opening(for: .real), .profile)
        XCTAssertEqual(ruler(draws: [], birthYear: nil).opening(for: .real), .profile)
    }

    func testEveryPageAPinOpensIsInTheMethodCatalog() {
        for kind in DataAgePinKind.allCases {
            if case .method(let id, _) = ruler(draws: []).opening(for: kind) {
                XCTAssertEqual(MethodCatalog.entry(id).group, .age, kind.rawValue)
            }
        }
    }
}
