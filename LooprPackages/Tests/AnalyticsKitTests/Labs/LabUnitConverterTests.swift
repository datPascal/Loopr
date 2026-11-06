import AnalyticsKit
import XCTest

private func dec(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func isClose(_ actual: Decimal, _ expected: Decimal, relative: Double = 1e-9) -> Bool {
    let difference = abs(NSDecimalNumber(decimal: actual - expected).doubleValue)
    let scale = max(abs(NSDecimalNumber(decimal: expected).doubleValue), 1e-12)
    return difference <= relative * scale
}

/// Every convertible pair of units each catalog marker lists, in both directions: marker, from, to, the number in
/// `from`, and the number it must become, worked out from the cited factors with exact decimal arithmetic.
private let convertiblePairs: [(LabMarkerKey, String, String, String, String)] = [
        (.albumin, "g/dL", "g/L", "4.5", "45"),
        (.albumin, "g/L", "g/dL", "45", "4.5"),
        (.creatinine, "mg/dL", "µmol/L", "1", "88.4"),
        (.creatinine, "µmol/L", "mg/dL", "88.4", "1"),
        (.glucose, "mg/dL", "mmol/L", "90", "4.99555950266"),
        (.glucose, "mmol/L", "mg/dL", "4.99555950266", "90"),
        (.crp, "mg/L", "mg/dL", "3", "0.3"),
        (.crp, "mg/dL", "mg/L", "0.3", "3"),
        (.meanCellVolume, "fL", "µm³", "90", "90"),
        (.meanCellVolume, "µm³", "fL", "90", "90"),
        (.alkalinePhosphatase, "U/L", "µkat/L", "72", "1.2"),
        (.alkalinePhosphatase, "µkat/L", "U/L", "1.2", "72"),
        (.whiteBloodCellCount, "10^3/µL", "10^9/L", "6.5", "6.5"),
        (.whiteBloodCellCount, "10^9/L", "10^3/µL", "6.5", "6.5"),
        (.apoB, "mg/dL", "g/L", "78", "0.78"),
        (.apoB, "g/L", "mg/dL", "0.78", "78"),
        (.hba1c, "%", "mmol/mol", "5.4", "35.51925"),
        (.hba1c, "mmol/mol", "%", "35.51925", "5.4"),
        (.ldlCholesterol, "mg/dL", "mmol/L", "100", "2.5859839669"),
        (.ldlCholesterol, "mmol/L", "mg/dL", "2.5859839669", "100"),
        (.hdlCholesterol, "mg/dL", "mmol/L", "60", "1.55159038014"),
        (.hdlCholesterol, "mmol/L", "mg/dL", "1.55159038014", "60"),
        (.totalCholesterol, "mg/dL", "mmol/L", "190", "4.91336953711"),
        (.totalCholesterol, "mmol/L", "mg/dL", "4.91336953711", "190"),
        (.triglycerides, "mg/dL", "mmol/L", "150", "1.69357570283"),
        (.triglycerides, "mmol/L", "mg/dL", "1.69357570283", "150"),
        (.fastingInsulin, "µIU/mL", "mIU/L", "8", "8"),
        (.fastingInsulin, "µIU/mL", "pmol/L", "8", "48"),
        (.fastingInsulin, "mIU/L", "µIU/mL", "8", "8"),
        (.fastingInsulin, "mIU/L", "pmol/L", "8", "48"),
        (.fastingInsulin, "pmol/L", "µIU/mL", "48", "8"),
        (.fastingInsulin, "pmol/L", "mIU/L", "48", "8"),
        (.ferritin, "ng/mL", "µg/L", "50", "50"),
        (.ferritin, "µg/L", "ng/mL", "50", "50"),
        (.vitaminD, "ng/mL", "nmol/L", "30", "74.88"),
        (.vitaminD, "nmol/L", "ng/mL", "74.88", "30"),
        (.tsh, "mIU/L", "µIU/mL", "2.1", "2.1"),
        (.tsh, "µIU/mL", "mIU/L", "2.1", "2.1"),
        (.alt, "U/L", "µkat/L", "30", "0.5"),
        (.alt, "µkat/L", "U/L", "0.5", "30"),
        (.ast, "U/L", "µkat/L", "24", "0.4"),
        (.ast, "µkat/L", "U/L", "0.4", "24"),
        (.ggt, "U/L", "µkat/L", "18", "0.3"),
        (.ggt, "µkat/L", "U/L", "0.3", "18"),
        (.uricAcid, "mg/dL", "µmol/L", "5", "297.4"),
        (.uricAcid, "mg/dL", "mmol/L", "5", "0.2974"),
        (.uricAcid, "µmol/L", "mg/dL", "297.4", "5"),
        (.uricAcid, "µmol/L", "mmol/L", "297.4", "0.2974"),
        (.uricAcid, "mmol/L", "mg/dL", "0.2974", "5"),
        (.uricAcid, "mmol/L", "µmol/L", "0.2974", "297.4"),
        (.hemoglobin, "g/dL", "g/L", "14", "140"),
        (.hemoglobin, "g/L", "g/dL", "140", "14"),
        (.platelets, "10^3/µL", "10^9/L", "250", "250"),
        (.platelets, "10^9/L", "10^3/µL", "250", "250"),
        (.homocysteine, "µmol/L", "mg/L", "10", "1.3519"),
        (.homocysteine, "mg/L", "µmol/L", "1.3519", "10"),
]

/// Every listed pair that must refuse, with the reason.
private let refusedPairs: [(LabMarkerKey, String, String, LabNoConversionReason)] = [
    (.crp, "mg/L", "nmol/L", .noCitedFactor), (.crp, "mg/dL", "nmol/L", .noCitedFactor),
    (.crp, "nmol/L", "mg/L", .noCitedFactor), (.crp, "nmol/L", "mg/dL", .noCitedFactor),
    (.lipoproteinA, "nmol/L", "mg/dL", .differentQuantities), (.lipoproteinA, "mg/dL", "nmol/L", .differentQuantities),
    (.ferritin, "ng/mL", "pmol/L", .noCitedFactor), (.ferritin, "µg/L", "pmol/L", .noCitedFactor),
    (.ferritin, "pmol/L", "ng/mL", .noCitedFactor), (.ferritin, "pmol/L", "µg/L", .noCitedFactor),
    (.hemoglobin, "g/dL", "mmol/L", .noCitedFactor), (.hemoglobin, "g/L", "mmol/L", .noCitedFactor),
    (.hemoglobin, "mmol/L", "g/dL", .noCitedFactor), (.hemoglobin, "mmol/L", "g/L", .noCitedFactor)
]

final class LabUnitConverterTests: XCTestCase {
    private let reportID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private func labValue(_ key: LabMarkerKey, _ text: String, unit: String?, printed: String? = nil) -> LabValue {
        LabValue(reportID: reportID, subject: .marker(key), value: dec(text), printedValue: printed, unit: unit, source: .typed)
    }

    // MARK: Every pair

    func testEveryListedUnitPairIsEitherConvertedOrRefusedWithATest() {
        var covered = Set<String>()
        for (marker, from, to, _, _) in convertiblePairs { covered.insert("\(marker.rawValue)|\(from)|\(to)") }
        for (marker, from, to, _) in refusedPairs { covered.insert("\(marker.rawValue)|\(from)|\(to)") }
        var expected = Set<String>()
        for marker in LabMarkerCatalog.markers {
            for from in marker.units {
                for to in marker.units where from != to { expected.insert("\(marker.key.rawValue)|\(from)|\(to)") }
            }
        }
        XCTAssertEqual(covered, expected)
        XCTAssertEqual(covered.count, convertiblePairs.count + refusedPairs.count, "a pair is listed twice")
    }

    func testEveryConvertiblePairConvertsToTheCitedResult() throws {
        for (marker, from, to, input, output) in convertiblePairs {
            let result = try LabUnitConverter.convert(dec(input), marker: marker, from: from, to: to)
            XCTAssertTrue(isClose(result, dec(output)), "\(marker.rawValue) \(input) \(from) -> \(to): got \(result), expected \(output)")
        }
    }

    func testEveryConvertiblePairRoundTripsWithinOnePartInATrillion() throws {
        for (marker, from, to, input, _) in convertiblePairs {
            let there = try LabUnitConverter.convert(dec(input), marker: marker, from: from, to: to)
            let back = try LabUnitConverter.convert(there, marker: marker, from: to, to: from)
            XCTAssertTrue(isClose(back, dec(input), relative: 1e-12), "\(marker.rawValue) \(from) <-> \(to): \(input) came back as \(back)")
        }
    }

    func testEveryRefusedPairThrowsATypedError() {
        for (marker, from, to, reason) in refusedPairs {
            XCTAssertThrowsError(try LabUnitConverter.convert(dec("10"), marker: marker, from: from, to: to), "\(marker.rawValue) \(from) -> \(to)") {
                XCTAssertEqual($0 as? LabUnitError, .noConversion(marker: marker, from: from, to: to, reason: reason))
            }
        }
    }

    func testTheSameUnitIsReturnedUnchangedEvenWhenItHasNoFactor() throws {
        for marker in LabMarkerCatalog.markers {
            for unit in marker.units {
                XCTAssertEqual(try LabUnitConverter.convert(dec("12.34"), marker: marker.key, from: unit, to: unit), dec("12.34"), "\(marker.key.rawValue) \(unit)")
            }
        }
    }

    func testPairsBetweenTwoNonCanonicalUnitsGoThroughTheCanonicalOne() throws {
        // Uric acid 297.4 µmol/L is 0.2974 mmol/L, and 5 mg/dL.
        XCTAssertTrue(isClose(try LabUnitConverter.convert(dec("297.4"), marker: .uricAcid, from: "µmol/L", to: "mmol/L"), dec("0.2974")))
        // Insulin 48 pmol/L is 8 mIU/L.
        XCTAssertTrue(isClose(try LabUnitConverter.convert(dec("48"), marker: .fastingInsulin, from: "pmol/L", to: "mIU/L"), dec("8")))
    }

    // MARK: The factors against a second published source

    func testFactorsAgreeWithLabcorpsRoundedSITableWithinOnePercent() throws {
        // Labcorp, SI Unit Conversion Table: conventional unit x factor = SI unit.
        let labcorp: [(LabMarkerKey, String, String, String, Double)] = [
            (.glucose, "mg/dL", "mmol/L", "100", 0.0555),
            (.creatinine, "mg/dL", "µmol/L", "1", 88.4),
            (.totalCholesterol, "mg/dL", "mmol/L", "200", 0.0259),
            (.ldlCholesterol, "mg/dL", "mmol/L", "100", 0.0259),
            (.hdlCholesterol, "mg/dL", "mmol/L", "50", 0.0259),
            (.triglycerides, "mg/dL", "mmol/L", "150", 0.0113),
            (.uricAcid, "mg/dL", "mmol/L", "5", 0.059),
            (.albumin, "g/dL", "g/L", "4", 10),
            (.ferritin, "ng/mL", "µg/L", "50", 1),
            (.fastingInsulin, "µIU/mL", "mIU/L", "8", 1),
            (.tsh, "µIU/mL", "mIU/L", "2", 1)
        ]
        for (marker, from, to, input, factor) in labcorp {
            let result = NSDecimalNumber(decimal: try LabUnitConverter.convert(dec(input), marker: marker, from: from, to: to)).doubleValue
            let published = (Double(input) ?? 0) * factor
            XCTAssertEqual(result, published, accuracy: published * 0.01, "\(marker.rawValue)")
        }
    }

    func testHbA1cFollowsTheIFCCMasterEquationAndAgreesWithNGSPsCurrentConstants() throws {
        XCTAssertTrue(isClose(try LabUnitConverter.convert(dec("2.15"), marker: .hba1c, from: "%", to: "mmol/mol"), dec("0")))
        XCTAssertTrue(isClose(try LabUnitConverter.convert(dec("6.5"), marker: .hba1c, from: "%", to: "mmol/mol"), dec("47.54115")))
        XCTAssertTrue(isClose(try LabUnitConverter.convert(dec("48"), marker: .hba1c, from: "mmol/mol", to: "%"), dec("6.542"), relative: 1e-3))
        // NGSP's current page: NGSP = 0.09148 x IFCC + 2.152. Both forms agree within 0.05 mmol/mol from 4 % to 12 %.
        var percent = 4.0
        while percent <= 12.0 {
            let ours = NSDecimalNumber(decimal: try LabUnitConverter.convert(dec(String(percent)), marker: .hba1c, from: "%", to: "mmol/mol")).doubleValue
            XCTAssertEqual(ours, (percent - 2.152) / 0.09148, accuracy: 0.05, "\(percent) %")
            percent += 0.5
        }
    }

    func testTheInsulinConventionIsSixPicomolesPerMicroInternationalUnit() throws {
        XCTAssertEqual(try LabUnitConverter.convert(dec("1"), marker: .fastingInsulin, from: "µIU/mL", to: "pmol/L"), dec("6"))
        XCTAssertNotEqual(try LabUnitConverter.convert(dec("1"), marker: .fastingInsulin, from: "µIU/mL", to: "pmol/L"), dec("6.945"))
    }

    func testEnzymeUnitsFollowTheKatalDefinition() throws {
        for marker in [LabMarkerKey.alt, .ast, .ggt, .alkalinePhosphatase] {
            let kat = NSDecimalNumber(decimal: try LabUnitConverter.convert(dec("1"), marker: marker, from: "U/L", to: "µkat/L")).doubleValue
            XCTAssertEqual(kat, 1.0 / 60.0, accuracy: 1e-12)
        }
    }

    // MARK: Citations

    func testEveryFactorCarriesACitationAndEveryNonCanonicalConvertibleUnitHasAFactor() {
        let factors = LabUnitConverter.factors
        XCTAssertFalse(factors.isEmpty)
        for factor in factors {
            XCTAssertFalse(factor.citation.trimmingCharacters(in: .whitespaces).isEmpty, factor.statement)
            XCTAssertFalse(factor.statement.isEmpty)
        }
        let withFactors = Set(factors.map { "\($0.marker.rawValue)|\($0.unit)" })
        for (marker, from, to, _, _) in convertiblePairs {
            let canonical = marker.marker.canonicalUnit
            for unit in [from, to] where unit != canonical {
                XCTAssertTrue(withFactors.contains("\(marker.rawValue)|\(unit)"), "\(marker.rawValue) \(unit) has no listed factor")
            }
        }
    }

    func testCitationsNameTheirSources() {
        let all = LabUnitConverter.factors.map(\.citation).joined(separator: "\n")
        for source in ["Labcorp", "PubChem", "Schwartz", "Knopp", "Hoelzel", "Mayo Clinic Laboratories", "IUPAC"] {
            XCTAssertTrue(all.contains(source), source)
        }
    }

    func testAConversionReportsTheCitationsOfTheFactorsItUsed() throws {
        let glucose = try LabUnitConverter.convert(labValue(.glucose, "90", unit: "mg/dL"), to: "mmol/L")
        XCTAssertEqual(glucose.citations.count, 1)
        XCTAssertTrue(glucose.citations[0].contains("PubChem CID 5793"))
        let uric = try LabUnitConverter.convert(labValue(.uricAcid, "297.4", unit: "µmol/L"), to: "mmol/L")
        XCTAssertEqual(uric.citations.count, 2)
        let same = try LabUnitConverter.convert(labValue(.glucose, "90", unit: "mg/dL"), to: "mg/dL")
        XCTAssertTrue(same.isUnchanged)
    }

    // MARK: Refusals

    func testUnknownAndMisspelledUnitsRefuse() {
        for text in ["mg/dl2", "mgdl", "mg per dl", "milligram", "mmol", "ml", "cells/µL", "10^6/L", "/µL", "IU", "xyz", "mg/dL."] {
            XCTAssertThrowsError(try LabUnitConverter.convert(labValue(.glucose, "90", unit: text), to: "mmol/L"), text) {
                XCTAssertEqual($0 as? LabUnitError, .unknownUnit(text))
            }
            XCTAssertThrowsError(try LabUnitConverter.convert(labValue(.glucose, "90", unit: "mg/dL"), to: text), text) {
                XCTAssertEqual($0 as? LabUnitError, .unknownUnit(text))
            }
        }
    }

    func testAKnownUnitTheMarkerIsNeverReportedInRefuses() {
        XCTAssertThrowsError(try LabUnitConverter.convert(dec("90"), marker: .glucose, from: "mg/dL", to: "g/L")) {
            XCTAssertEqual($0 as? LabUnitError, .unitNotListedForMarker(marker: .glucose, unit: "g/L"))
        }
        XCTAssertThrowsError(try LabUnitConverter.convert(dec("5"), marker: .egfr, from: "mL/min/1.73 m²", to: "mg/dL")) {
            XCTAssertEqual($0 as? LabUnitError, .unitNotListedForMarker(marker: .egfr, unit: "mg/dL"))
        }
    }

    func testAPercentageAgainstAnAbsoluteCountRefuses() {
        for unit in ["10^9/L", "10^3/µL"] {
            XCTAssertThrowsError(try LabUnitConverter.convert(dec("1.8"), marker: .lymphocytePercent, from: unit, to: "%")) {
                XCTAssertEqual($0 as? LabUnitError, .noConversion(marker: .lymphocytePercent, from: unit, to: "%", reason: .percentageAgainstAbsoluteCount))
            }
            XCTAssertThrowsError(try LabUnitConverter.convert(dec("30"), marker: .lymphocytePercent, from: "%", to: unit)) {
                XCTAssertEqual($0 as? LabUnitError, .noConversion(marker: .lymphocytePercent, from: "%", to: unit, reason: .percentageAgainstAbsoluteCount))
            }
        }
        XCTAssertThrowsError(try LabUnitConverter.convert(labValue(.lymphocytePercent, "1.8", unit: "G/L"), to: "%")) {
            XCTAssertEqual($0 as? LabUnitError, .noConversion(marker: .lymphocytePercent, from: "10^9/L", to: "%", reason: .percentageAgainstAbsoluteCount))
        }
    }

    func testLipoproteinAInNanomolesAndMilligramsNeverConverts() {
        XCTAssertThrowsError(try LabUnitConverter.convert(labValue(.lipoproteinA, "75", unit: "nmol/L"), to: "mg/dL")) {
            XCTAssertEqual($0 as? LabUnitError, .noConversion(marker: .lipoproteinA, from: "nmol/L", to: "mg/dL", reason: .differentQuantities))
        }
    }

    func testAValueWithoutAUnitOrForAnOtherTestRefuses() {
        XCTAssertThrowsError(try LabUnitConverter.convert(labValue(.glucose, "90", unit: nil), to: "mmol/L")) {
            XCTAssertEqual($0 as? LabUnitError, .missingUnit)
        }
        let other = LabValue(reportID: reportID, subject: .other(name: "Selenium"), value: dec("110"), unit: "µg/L", source: .typed)
        XCTAssertThrowsError(try LabUnitConverter.convert(other, to: "nmol/L")) {
            XCTAssertEqual($0 as? LabUnitError, .otherValueHasNoUnits)
        }
    }

    // MARK: Precision

    func testAConversionKeepsFullPrecisionAndTheSourceDigits() throws {
        let hba1c = try LabUnitConverter.convert(labValue(.hba1c, "5", unit: "%", printed: "5.0"), to: "mmol/mol")
        XCTAssertEqual(hba1c.sourcePrintedValue, "5.0")
        XCTAssertEqual(hba1c.sourceValue, dec("5"))
        XCTAssertEqual(hba1c.sourceUnit, "%")
        XCTAssertEqual(hba1c.unit, "mmol/mol")
        XCTAssertTrue(isClose(hba1c.value, dec("31.14765")))

        let glucose = try LabUnitConverter.convert(labValue(.glucose, "90", unit: "mg/dL"), to: "mmol/L")
        XCTAssertNil(glucose.sourcePrintedValue)
        XCTAssertNotEqual(glucose.value, glucose.rounded(fractionDigits: 1))
        XCTAssertEqual(glucose.rounded(fractionDigits: 1), dec("5.0"))
        XCTAssertEqual(glucose.rounded(fractionDigits: 2), dec("5.00"))
        XCTAssertEqual(glucose.rounded(fractionDigits: 4), dec("4.9956"))
        XCTAssertGreaterThan(NSDecimalNumber(decimal: glucose.value).stringValue.count, 12)
    }

    func testConvertingTheValueDoesNotChangeIt() throws {
        let stored = labValue(.glucose, "5.5", unit: "mmol/L")
        _ = try LabUnitConverter.convert(stored, to: "mg/dL")
        XCTAssertEqual(stored.value, dec("5.5"))
        XCTAssertEqual(stored.unit, "mmol/L")
    }

    // MARK: PhenoAge input units

    func testPhenoAgeInputsAreRequestedInTheEnginesUnits() {
        let expected: [LabMarkerKey: String] = [
            .albumin: "g/L", .creatinine: "µmol/L", .glucose: "mmol/L", .crp: "mg/dL", .lymphocytePercent: "%",
            .meanCellVolume: "fL", .redCellDistributionWidth: "%", .alkalinePhosphatase: "U/L", .whiteBloodCellCount: "10^3/µL"
        ]
        for marker in LabMarkerCatalog.phenoAgeInputs { XCTAssertEqual(LabUnitConverter.phenoAgeUnit(for: marker.key), expected[marker.key], marker.key.rawValue) }
        XCTAssertEqual(Set(expected.keys), Set(LabMarkerCatalog.phenoAgeInputs.map(\.key)))
        XCTAssertNil(LabUnitConverter.phenoAgeUnit(for: .apoB))
        for (key, unit) in expected { XCTAssertTrue(key.marker.units.contains(unit), "\(key.rawValue) \(unit)") }
    }

    func testEveryPhenoAgeInputConvertsFromEveryUnitItIsReportedIn() throws {
        // The same blood draw, written in each listed unit, must give the same PhenoAge input.
        let draw: [(LabMarkerKey, [(String, String)], String)] = [
            (.albumin, [("g/dL", "4.5"), ("g/L", "45")], "45"),
            (.creatinine, [("mg/dL", "1"), ("µmol/L", "88.4")], "88.4"),
            (.glucose, [("mg/dL", "90.144"), ("mmol/L", "5.004")], "5.004"),
            (.crp, [("mg/L", "3"), ("mg/dL", "0.3")], "0.3"),
            (.lymphocytePercent, [("%", "30")], "30"),
            (.meanCellVolume, [("fL", "90"), ("µm³", "90")], "90"),
            (.redCellDistributionWidth, [("%", "13")], "13"),
            (.alkalinePhosphatase, [("U/L", "72"), ("µkat/L", "1.2")], "72"),
            (.whiteBloodCellCount, [("10^3/µL", "6.5"), ("10^9/L", "6.5")], "6.5")
        ]
        for (marker, writings, target) in draw {
            for (unit, number) in writings {
                let result = try LabUnitConverter.phenoAgeValue(labValue(marker, number, unit: unit))
                XCTAssertEqual(result.unit, LabUnitConverter.phenoAgeUnit(for: marker), marker.rawValue)
                XCTAssertTrue(isClose(result.value, dec(target), relative: 1e-3), "\(marker.rawValue) \(number) \(unit): got \(result.value), expected \(target)")
            }
        }
    }

    func testPhenoAgeRefusesWhatItCannotConvertOrDoesNotUse() {
        XCTAssertThrowsError(try LabUnitConverter.phenoAgeValue(labValue(.apoB, "78", unit: "mg/dL"))) {
            XCTAssertEqual($0 as? LabUnitError, .notAPhenoAgeInput(.apoB))
        }
        XCTAssertThrowsError(try LabUnitConverter.phenoAgeValue(labValue(.crp, "20", unit: "nmol/L"))) {
            XCTAssertEqual($0 as? LabUnitError, .noConversion(marker: .crp, from: "nmol/L", to: "mg/dL", reason: .noCitedFactor))
        }
        XCTAssertThrowsError(try LabUnitConverter.phenoAgeValue(labValue(.lymphocytePercent, "1.8", unit: "10^9/L")))
        XCTAssertThrowsError(try LabUnitConverter.phenoAgeValue(labValue(.albumin, "4.5", unit: nil))) {
            XCTAssertEqual($0 as? LabUnitError, .missingUnit)
        }
    }
}

final class LabUnitTextTests: XCTestCase {
    func testEveryCatalogUnitSymbolMapsToItself() {
        for marker in LabMarkerCatalog.markers {
            for unit in marker.units { XCTAssertEqual(LabUnitText.symbol(forPrinted: unit), unit, "\(marker.key.rawValue) \(unit)") }
        }
    }

    func testCommonPrintedVariantsMapToTheCatalogSymbol() {
        let variants: [(String, String)] = [
            // Micro sign, Greek mu and u.
            ("µmol/L", "µmol/L"), ("\u{03BC}mol/L", "µmol/L"), ("umol/L", "µmol/L"), ("UMOL/L", "µmol/L"),
            ("ug/L", "µg/L"), ("μg/l", "µg/L"), ("ukat/L", "µkat/L"), ("uIU/mL", "µIU/mL"), ("µU/mL", "µIU/mL"),
            ("um3", "µm³"), ("µm^3", "µm³"),
            // Case and spacing.
            ("mg/dl", "mg/dL"), ("MG/DL", "mg/dL"), ("mg / dL", "mg/dL"), (" mg/dL ", "mg/dL"), ("mg/\u{00A0}dL", "mg/dL"),
            ("mmol/l", "mmol/L"), ("g/dl", "g/dL"),
            // German reports.
            ("g/l", "g/L"), ("mg/l", "mg/L"), ("mmol/mol Hb", "mmol/mol"), ("ml/min/1,73m²", "mL/min/1.73 m²"),
            ("Tsd./µl", "10^3/µL"), ("Tsd/µl", "10^3/µL"), ("Gpt/l", "10^9/L"), ("Gpt/L", "10^9/L"), ("G/L", "10^9/L"), ("/nl", "10^9/L"),
            // Cell counts.
            ("10^9/L", "10^9/L"), ("x10E9/L", "10^9/L"), ("x10^9/L", "10^9/L"), ("10E9/L", "10^9/L"), ("10*9/L", "10^9/L"),
            ("×10⁹/L", "10^9/L"), ("10⁹/L", "10^9/L"),
            ("10^3/uL", "10^3/µL"), ("x10E3/uL", "10^3/µL"), ("x10^3/µL", "10^3/µL"), ("K/uL", "10^3/µL"), ("10³/µL", "10^3/µL"),
            // Enzymes and hormones.
            ("IU/L", "U/L"), ("u/l", "U/L"), ("mIU/L", "mIU/L"), ("mU/L", "mIU/L"), ("miu/l", "mIU/L"),
            ("fl", "fL"), ("ml/min/1.73m2", "mL/min/1.73 m²"), ("mL/min/1.73 m^2", "mL/min/1.73 m²")
        ]
        for (printed, symbol) in variants {
            XCTAssertEqual(LabUnitText.symbol(forPrinted: printed), symbol, printed)
        }
    }

    func testGramsPerLitreAndGigaPerLitreStayApart() {
        XCTAssertEqual(LabUnitText.symbol(forPrinted: "g/L"), "g/L")
        XCTAssertEqual(LabUnitText.symbol(forPrinted: "g/l"), "g/L")
        XCTAssertEqual(LabUnitText.symbol(forPrinted: "G/L"), "10^9/L")
        XCTAssertEqual(LabUnitText.symbol(forPrinted: "G/l"), "10^9/L")
    }

    func testNothingElseIsAccepted() {
        let refused = [
            "", " ", "mg", "dL", "mg/dl2", "mgdl", "mg per dL", "mg/100mL", "mmol", "mol/L", "cells/µL", "/µL", "10^6/L", "10^12/L",
            "T/L", "Mio/µl", "x10E6/L", "IU", "kat/L", "mcg/dL", "ng/dL", "mmol/L Hb", "percent", "pct", "mg/dL.", "µ", "G", "L"
        ]
        for text in refused { XCTAssertNil(LabUnitText.symbol(forPrinted: text), text) }
    }
}
