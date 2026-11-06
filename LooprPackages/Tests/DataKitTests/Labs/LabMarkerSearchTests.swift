import AnalyticsKit
import DataKit
import XCTest

final class LabMarkerSearchTests: XCTestCase {
    private func keys(_ query: String) -> [LabMarkerKey] { LabMarkerSearch.results(for: query).map(\.key) }

    func testAnEmptyQueryListsTheWholeCatalogInItsOwnOrder() {
        XCTAssertEqual(keys("  "), LabMarkerCatalog.markers.map(\.key))
    }

    func testEnglishNamesAndAbbreviationsFindTheirMarker() {
        XCTAssertEqual(keys("albumin").first, .albumin)
        XCTAssertEqual(keys("apolipo").first, .apoB)
        XCTAssertEqual(keys("hs-crp").first, .crp)
        XCTAssertEqual(keys("white blood").first, .whiteBloodCellCount)
        XCTAssertEqual(keys("ldl").first, .ldlCholesterol)
        XCTAssertEqual(keys("a1c").first, .hba1c)
    }

    func testGermanNamesFindTheirMarkerWithOrWithoutUmlauts() {
        XCTAssertEqual(keys("Kreatinin").first, .creatinine)
        XCTAssertEqual(keys("Leukozyten").first, .whiteBloodCellCount)
        XCTAssertEqual(keys("Harnsäure").first, .uricAcid)
        XCTAssertEqual(keys("harnsaeure").first, .uricAcid)
        XCTAssertEqual(keys("Hämoglobin").first, .hemoglobin)
        XCTAssertEqual(keys("haemoglobin").first, .hemoglobin)
        XCTAssertEqual(keys("Thrombozyten").first, .platelets)
        XCTAssertEqual(keys("GPT").first, .alt)
        XCTAssertEqual(keys("GOT").first, .ast)
        XCTAssertEqual(keys("Gamma-GT").first, .ggt)
        XCTAssertEqual(keys("Lymphozyten").first, .lymphocytePercent)
        XCTAssertEqual(keys("Gesamtcholesterin").first, .totalCholesterol)
    }

    func testExactMatchesRankAheadOfPartialOnes() {
        XCTAssertEqual(keys("hdl").first, .hdlCholesterol)
        XCTAssertEqual(keys("alt").first, .alt)
        XCTAssertTrue(keys("cholesterol").contains(.ldlCholesterol))
    }

    func testANameNobodyListsFindsNothing() {
        XCTAssertTrue(keys("zinc").isEmpty)
    }

    func testEveryCatalogMarkerAnswersToItsOwnName() {
        for marker in LabMarkerCatalog.markers {
            XCTAssertTrue(keys(marker.displayName).contains(marker.key), marker.displayName)
        }
    }
}
