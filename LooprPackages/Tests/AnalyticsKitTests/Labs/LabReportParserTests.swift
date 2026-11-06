@testable import AnalyticsKit
import XCTest

private func dec(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private let berlin = TimeZone(identifier: "Europe/Berlin")!

private func berlinDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = berlin
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// The photo was taken on 14 September 2026.
private let capturedAt = berlinDate(2026, 9, 14)

private struct FixtureFile: Decodable {
    struct Entry: Decodable { let text: String; let x: Double; let y: Double; let w: Double; let h: Double; let c: Double }
    let lines: [Entry]
}

private func fixtureLines(_ name: String) throws -> [LabTextLine] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/LabReports"))
    let file = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
    return file.lines.map { LabTextLine(text: $0.text, minX: $0.x, minY: $0.y, width: $0.w, height: $0.h, confidence: $0.c) }
}

/// One line per row, top to bottom.
private func rows(_ texts: [String], confidence: Double = 0.98) -> [LabTextLine] {
    texts.enumerated().map { index, text in
        LabTextLine(text: text, minX: 0.05, minY: 0.95 - Double(index) * 0.03, width: 0.9, height: 0.015, confidence: confidence)
    }
}

private func parse(_ texts: [String], confidence: Double = 0.98, options: LabReportParser.Options = .init()) -> LabReportDraft {
    LabReportParser.parse(lines: rows(texts, confidence: confidence), capturedAt: capturedAt, timeZone: berlin, options: options)
}

private func parse(lines: [LabTextLine]) -> LabReportDraft {
    LabReportParser.parse(lines: lines, capturedAt: capturedAt, timeZone: berlin)
}

private func markerValue(_ draft: LabReportDraft, _ key: LabMarkerKey) -> LabValue? {
    draft.values.first { $0.subject == .marker(key) }
}

private func otherValue(_ draft: LabReportDraft, _ name: String) -> LabValue? {
    draft.values.first { $0.subject == .other(name: name) }
}

final class LabReportParserFormTests: XCTestCase {
    // MARK: Ranges

    func testReferenceRangeForms() throws {
        let cases: [(String, Decimal?, Decimal?, String?)] = [
            ("Albumin 4.6 g/dL 3.5 - 5.2", dec("3.5"), dec("5.2"), nil),
            ("Albumin 4.6 g/dL 3.5-5.2", dec("3.5"), dec("5.2"), nil),
            ("Albumin 4.6 g/dL 3.5 – 5.2", dec("3.5"), dec("5.2"), nil),
            ("Kreatinin 0,9 mg/dl 3,5-5,2", dec("3.5"), dec("5.2"), nil),
            ("Kreatinin 0,9 mg/dl 3,5 - 5,2", dec("3.5"), dec("5.2"), nil),
            ("Kreatinin 0,9 mg/dl (3,5 - 5,2)", dec("3.5"), dec("5.2"), nil),
            ("Kreatinin 0,9 mg/dl (3,5-5,2)", dec("3.5"), dec("5.2"), nil),
            ("Albumin 4.6 g/dL Ref.: 3.5 to 5.2", dec("3.5"), dec("5.2"), nil),
            ("Albumin 4.6 g/dL Ref: 3.5 to 5.2", dec("3.5"), dec("5.2"), nil),
            ("Albumin 46 g/l Referenz: 35 bis 52", dec("35"), dec("52"), nil),
            ("Albumin 46 g/l Referenzbereich: 35 - 52", dec("35"), dec("52"), nil),
            ("CRP 0.6 mg/L < 5.0", nil, nil, "<5.0"),
            ("CRP 0.6 mg/L <5.0", nil, nil, "<5.0"),
            ("CRP 0,6 mg/l < 5,0", nil, nil, "<5,0"),
            ("CRP 0.6 mg/L <= 5", nil, nil, "<=5"),
            ("HDL-Cholesterin 58 mg/dl > 60", nil, nil, ">60"),
            ("Ferritin 96 µg/l ≤ 150", nil, nil, "≤150"),
            ("Ferritin 96 µg/l ≥ 30", nil, nil, "≥30"),
            ("Mikroalbumin 8 mg/l negativ", nil, nil, "negativ"),
            ("Mikroalbumin 8 mg/l Ref.: negativ", nil, nil, "negativ"),
            ("Albumin 4.6 g/dL", nil, nil, nil)
        ]
        for (row, low, high, text) in cases {
            let draft = parse([row])
            let read = try XCTUnwrap(draft.values.first, row)
            XCTAssertEqual(read.referenceRange.low, low, row)
            XCTAssertEqual(read.referenceRange.high, high, row)
            XCTAssertEqual(read.referenceRange.text, text, row)
        }
    }

    func testARangeAfterTheUnitAndAUnitAfterTheRangeBothRead() throws {
        let afterRange = try XCTUnwrap(parse(["Albumin 4.6 3.5 - 5.2 g/dL"]).values.first)
        XCTAssertEqual(afterRange.unit, "g/dL")
        XCTAssertEqual(afterRange.referenceRange.low, dec("3.5"))
    }

    // MARK: Flags

    func testFlagsAreKeptAsPrinted() throws {
        let cases: [(String, String)] = [
            ("Ferritin 412 * ng/mL 30 - 400", "*"),
            ("Ferritin 412 ng/mL 30 - 400 H", "H"),
            ("Ferritin 412 H ng/mL 30 - 400", "H"),
            ("Ferritin 12 L ng/mL 30 - 400", "L"),
            ("Ferritin 412 ↑ ng/mL 30 - 400", "↑"),
            ("Ferritin 12 ↓ ng/mL 30 - 400", "↓"),
            ("Ferritin 3.0 + ng/mL 30 - 400", "+"),
            ("Ferritin 5.4H ng/mL 30 - 400", "H"),
            ("Ferritin 41,2↓ ng/ml 30 - 400", "↓"),
            ("Ferritin 412* ng/mL 30 - 400", "*"),
            ("Ferritin 412 HH ng/mL", "HH")
        ]
        for (row, flag) in cases {
            let read = try XCTUnwrap(parse([row]).values.first, row)
            XCTAssertEqual(read.flagText, flag, row)
            XCTAssertEqual(read.subject, .marker(.ferritin), row)
        }
        XCTAssertNil(try XCTUnwrap(parse(["Ferritin 96 ng/mL 30 - 400"]).values.first).flagText)
    }

    func testTheParserNeverSetsAFlagTheLabDidNotPrint() throws {
        // 412 is above the printed range and 12 below it. The parser says nothing about either.
        for row in ["Ferritin 412 ng/mL 30 - 400", "Ferritin 12 ng/mL 30 - 400"] {
            let read = try XCTUnwrap(parse([row]).values.first)
            XCTAssertNil(read.flagText)
            XCTAssertFalse(read.needsReview)
        }
    }

    // MARK: Decimals

    func testDecimalCommasAndPointsReadToTheSameNumber() throws {
        for row in ["Kreatinin 0,82 mg/dl", "Kreatinin 0.82 mg/dl"] {
            XCTAssertEqual(try XCTUnwrap(parse([row]).values.first).value, dec("0.82"), row)
        }
        XCTAssertEqual(try XCTUnwrap(parse(["Ferritin 1.234,5 µg/l"]).values.first).value, dec("1234.5"))
        XCTAssertEqual(try XCTUnwrap(parse(["Ferritin 1,234.5 ng/mL"]).values.first).value, dec("1234.5"))
        XCTAssertEqual(try XCTUnwrap(parse(["Ferritin 12 ng/mL"]).values.first).value, dec("12"))
        XCTAssertEqual(try XCTUnwrap(parse(["Ferritin 0,123 ng/mL"]).values.first).value, dec("0.123"))
    }

    func testTrailingZerosSurviveAsThePrintedValue() throws {
        let uric = try XCTUnwrap(parse(["Harnsäure 5,0 mg/dl"]).values.first)
        XCTAssertEqual(uric.value, dec("5"))
        XCTAssertEqual(uric.printedValue, "5.0")
        XCTAssertEqual(uric.displayValue, "5.0")
        XCTAssertNil(try XCTUnwrap(parse(["Harnsäure 5,4 mg/dl"]).values.first).printedValue)
        XCTAssertEqual(try XCTUnwrap(parse(["TSH 1,90 mIU/l"]).values.first).printedValue, "1.90")
    }

    func testALoneSeparatorBeforeThreeDigitsIsReadByTheReportsDecimalStyle() throws {
        let german = parse(["Kreatinin 0,5 mg/dl", "Thrombozyten 1.250 /nl"])
        let platelets = try XCTUnwrap(markerValue(german, .platelets))
        XCTAssertEqual(platelets.value, dec("1250"))
        XCTAssertTrue(platelets.needsReview, "the separator was ambiguous")

        let english = parse(["Creatinine 0.5 mg/dL", "Platelets 1,250 x10E3/uL"])
        XCTAssertEqual(try XCTUnwrap(markerValue(english, .platelets)).value, dec("1250"))
        XCTAssertTrue(try XCTUnwrap(markerValue(english, .platelets)).needsReview)

        let germanDecimal = parse(["Kreatinin 0,5 mg/dl", "Ferritin 1,234 µg/l"])
        XCTAssertEqual(try XCTUnwrap(markerValue(germanDecimal, .ferritin)).value, dec("1.234"))

        // With nothing to say which style the report uses, the number is not guessed.
        let unknown = parse(["Thrombozyten 1.250 /nl"])
        XCTAssertTrue(unknown.values.isEmpty)
        XCTAssertEqual(unknown.rowsSkipped, 1)
    }

    func testADateInTheValueColumnIsNotANumber() {
        let draft = parse(["Kreatinin 12.09.2026"])
        XCTAssertTrue(draft.values.isEmpty)
        XCTAssertEqual(draft.rowsSkipped, 1)
    }

    // MARK: Names

    func testEveryGermanAndEnglishNameReadsToItsMarker() throws {
        let cases: [(String, LabMarkerKey, String)] = [
            ("Kreatinin 0,9 mg/dl", .creatinine, "mg/dl"),
            ("Creatinine 0.9 mg/dL", .creatinine, "mg/dL"),
            ("Glukose 90 mg/dl", .glucose, "mg/dl"),
            ("Glucose nüchtern 90 mg/dl", .glucose, "mg/dl"),
            ("Glukose nüchtern 5,0 mmol/l", .glucose, "mmol/l"),
            ("Glucose, fasting 88 mg/dL", .glucose, "mg/dL"),
            ("Albumin 46 g/l", .albumin, "g/l"),
            ("CRP 0,6 mg/l", .crp, "mg/l"),
            ("hs-CRP 0,6 mg/l", .crp, "mg/l"),
            ("C-reaktives Protein 0,6 mg/l", .crp, "mg/l"),
            ("Lymphozyten % 31 %", .lymphocytePercent, "%"),
            ("Lymphozyten 31 %", .lymphocytePercent, "%"),
            ("Lymphocytes % 31 %", .lymphocytePercent, "%"),
            ("MCV 89 fl", .meanCellVolume, "fl"),
            ("RDW 13 %", .redCellDistributionWidth, "%"),
            ("Alkalische Phosphatase 64 U/l", .alkalinePhosphatase, "U/l"),
            ("Alkaline phosphatase 64 U/L", .alkalinePhosphatase, "U/L"),
            ("Leukozyten 5,9 /nl", .whiteBloodCellCount, "/nl"),
            ("White blood cells 5.9 x10E3/uL", .whiteBloodCellCount, "x10E3/uL"),
            ("HbA1c 5,2 %", .hba1c, "%"),
            ("HbA1c 33 mmol/mol", .hba1c, "mmol/mol"),
            ("Apolipoprotein B 0,78 g/l", .apoB, "g/l"),
            ("Lipoprotein(a) 38 nmol/l", .lipoproteinA, "nmol/l"),
            ("Lp(a) 38 nmol/L", .lipoproteinA, "nmol/L"),
            ("LDL-Cholesterin 92 mg/dl", .ldlCholesterol, "mg/dl"),
            ("HDL-Cholesterin 58 mg/dl", .hdlCholesterol, "mg/dl"),
            ("Triglyzeride 71 mg/dl", .triglycerides, "mg/dl"),
            ("Cholesterin gesamt 190 mg/dl", .totalCholesterol, "mg/dl"),
            ("Total cholesterol 190 mg/dL", .totalCholesterol, "mg/dL"),
            ("Ferritin 96 µg/l", .ferritin, "µg/l"),
            ("25-OH-Vitamin D 41 ng/ml", .vitaminD, "ng/ml"),
            ("Vitamin D, 25-hydroxy 41 ng/mL", .vitaminD, "ng/mL"),
            ("TSH 1,9 mIU/l", .tsh, "mIU/l"),
            ("GOT/AST 24 U/l", .ast, "U/l"),
            ("GOT (AST) 24 U/l", .ast, "U/l"),
            ("AST 24 U/L", .ast, "U/L"),
            ("GPT/ALT 22 U/l", .alt, "U/l"),
            ("GPT (ALT) 22 U/l", .alt, "U/l"),
            ("ALT 22 U/L", .alt, "U/L"),
            ("Gamma-GT 17 U/l", .ggt, "U/l"),
            ("γ-GT 17 U/l", .ggt, "U/l"),
            ("eGFR 108 ml/min/1,73m²", .egfr, "ml/min/1,73m²"),
            ("eGFR (CKD-EPI) 108 ml/min/1,73m²", .egfr, "ml/min/1,73m²"),
            ("Harnsäure 5,0 mg/dl", .uricAcid, "mg/dl"),
            ("Uric acid 5.0 mg/dL", .uricAcid, "mg/dL"),
            ("Hämoglobin 14,6 g/dl", .hemoglobin, "g/dl"),
            ("Hemoglobin 14.6 g/dL", .hemoglobin, "g/dL"),
            ("Thrombozyten 231 /nl", .platelets, "/nl"),
            ("Platelets 231 x10E3/uL", .platelets, "x10E3/uL"),
            ("Homocystein 9,2 µmol/l", .homocysteine, "µmol/l"),
            ("Insulin 5,1 µU/ml", .fastingInsulin, "µU/ml")
        ]
        for (row, key, unit) in cases {
            let draft = parse([row])
            let read = try XCTUnwrap(draft.values.first, row)
            XCTAssertEqual(draft.values.count, 1, row)
            XCTAssertEqual(read.subject, .marker(key), row)
            XCTAssertEqual(read.unit, unit, row)
            XCTAssertFalse(read.needsReview, row)
        }
    }

    func testBothLanguagesCoverTheWholeCatalog() throws {
        for name in ["en-report", "de-report"] {
            let draft = parse(lines: try fixtureLines(name))
            let keys = draft.values.compactMap(\.subject.markerKey)
            XCTAssertEqual(Set(keys), Set(LabMarkerKey.allCases), name)
            XCTAssertEqual(keys.count, LabMarkerKey.allCases.count, "\(name): each marker once")
        }
    }

    func testHsCrpAndCrpAreOneMarkerWithTheAssayNoted() throws {
        let cases: [(String, String)] = [
            ("hs-CRP 0,6 mg/l", "hs-CRP"), ("CRP (hochsensitiv) 0,6 mg/l", "hs-CRP"), ("High sensitivity CRP 0.6 mg/L", "hs-CRP"),
            ("CRP 0,6 mg/l", "CRP"), ("C-reaktives Protein 0,6 mg/l", "CRP"), ("C-reactive protein 0.6 mg/L", "CRP")
        ]
        for (row, assay) in cases {
            let read = try XCTUnwrap(parse([row]).values.first, row)
            XCTAssertEqual(read.subject, .marker(.crp), row)
            XCTAssertEqual(read.assay, assay, row)
        }
        XCTAssertNil(try XCTUnwrap(parse(["Albumin 46 g/l"]).values.first).assay)
    }

    func testAnUnknownTestKeepsItsPrintedNameAsAnOtherValue() throws {
        let draft = parse(["Vitamin B12, Active 88 pmol/L 40 - 120", "Selen 95 µg/l 70 - 150", "Zink i.S. 81 µg/dl 66 - 110"])
        let b12 = try XCTUnwrap(otherValue(draft, "Vitamin B12, Active"))
        XCTAssertEqual(b12.value, dec("88"))
        XCTAssertEqual(b12.unit, "pmol/L")
        XCTAssertEqual(b12.referenceRange.low, dec("40"))
        XCTAssertFalse(b12.needsReview)
        XCTAssertNotNil(otherValue(draft, "Selen"))
        XCTAssertEqual(draft.values.count, 3)
        XCTAssertTrue(draft.values.allSatisfy { $0.subject.markerKey == nil })
    }

    func testRDWSDIsNotRDWAndAnAbsoluteLymphocyteCountIsNotThePercentage() throws {
        let sd = parse(["RDW-SD 42,1 fl 35,0 - 46,0"])
        XCTAssertNil(markerValue(sd, .redCellDistributionWidth))
        XCTAssertNotNil(otherValue(sd, "RDW-SD"))

        let absolute = parse(["Lymphozyten 1,8 G/l 1,0 - 4,0"])
        XCTAssertNil(markerValue(absolute, .lymphocytePercent))
        let read = try XCTUnwrap(otherValue(absolute, "Lymphozyten"))
        XCTAssertEqual(read.unit, "G/l")
        XCTAssertEqual(read.value, dec("1.8"))
    }

    func testWordsThatAreNotTestsAreNotValues() {
        let draft = parse(["Seite 1 von 2", "Tel. 030 1234567", "Datum: 12.09.2026", "Befund vom 14.09.2026", "Kunden-Nr. 4711"])
        XCTAssertTrue(draft.values.isEmpty)
        XCTAssertEqual(draft.rowsSkipped, 0)
    }

    // MARK: Units

    func testAMissingUnitIsNeverFilledIn() throws {
        let read = try XCTUnwrap(parse(["Kreatinin 0,9 0,6 - 1,1"]).values.first)
        XCTAssertNil(read.unit)
        XCTAssertTrue(read.needsReview)
        XCTAssertEqual(read.referenceRange.low, dec("0.6"))
        let bare = try XCTUnwrap(parse(["Kreatinin 0,9"]).values.first)
        XCTAssertNil(bare.unit)
        XCTAssertTrue(bare.needsReview)
    }

    func testAUnitTheMarkerIsNotReportedInIsDroppedAndFlagged() throws {
        let read = try XCTUnwrap(parse(["HDL-Cholesterin 1,5 g/l > 0,4"]).values.first)
        XCTAssertEqual(read.subject, .marker(.hdlCholesterol))
        XCTAssertNil(read.unit)
        XCTAssertTrue(read.needsReview)
        XCTAssertEqual(read.value, dec("1.5"))
        let glucose = try XCTUnwrap(parse(["Glukose 5,0 g/dl"]).values.first)
        XCTAssertNil(glucose.unit)
        XCTAssertTrue(glucose.needsReview)
    }

    func testAnUnrecognisedUnitLeavesTheUnitNilAndFlagsTheRow() throws {
        let marker = try XCTUnwrap(parse(["Kreatinin 0,9 mg/100ml 0,6 - 1,1"]).values.first)
        XCTAssertNil(marker.unit)
        XCTAssertTrue(marker.needsReview)
        XCTAssertEqual(marker.referenceRange.high, dec("1.1"))
        let unknown = try XCTUnwrap(otherValue(parse(["Free Testosterone 14.2 ng/dL 8.7 - 25.1"]), "Free Testosterone"))
        XCTAssertNil(unknown.unit)
        XCTAssertTrue(unknown.needsReview)
        XCTAssertEqual(unknown.referenceRange.high, dec("25.1"))
    }

    func testTheParserNeverConvertsAUnit() throws {
        let glucose = try XCTUnwrap(parse(["Glukose 5,0 mmol/l"]).values.first)
        XCTAssertEqual(glucose.value, dec("5"))
        XCTAssertEqual(glucose.unit, "mmol/l")
        let creatinine = try XCTUnwrap(parse(["Kreatinin 79,6 µmol/l"]).values.first)
        XCTAssertEqual(creatinine.value, dec("79.6"))
        XCTAssertEqual(creatinine.unit, "µmol/l")
    }

    func testAUnitSplitAcrossTokensOrGluedToTheValueReadsAsPrinted() throws {
        XCTAssertEqual(try XCTUnwrap(parse(["Kreatinin 0,9 mg / dl 0,6 - 1,1"]).values.first).unit, "mg/dl")
        XCTAssertEqual(try XCTUnwrap(parse(["Kreatinin 0,9mg/dl 0,6-1,1"]).values.first).unit, "mg/dl")
        XCTAssertEqual(try XCTUnwrap(parse(["CRP 0.6mg/L"]).values.first).value, dec("0.6"))
        XCTAssertEqual(try XCTUnwrap(parse(["HbA1c 5,2% 4,0 - 5,6"]).values.first).unit, "%")
        XCTAssertEqual(try XCTUnwrap(parse(["HbA1c 33 mmol/mol Hb 20 - 38"]).values.first).unit, "mmol/molHb")
    }

    // MARK: Skipped rows

    func testRowsWhoseValueCannotBeReadAreSkippedAndCounted() {
        let draft = parse([
            "CRP < 0,3 mg/l < 5",
            "CRP negativ",
            "Kreatinin mg/dl 0,6 - 1,1",
            "Homocystein 9?2 µmol/l < 12",
            "Albumin 46 g/l 35 - 52"
        ])
        // "< 0,3" is a result printed as a limit, so it reads. The other three cannot be read.
        XCTAssertEqual(draft.valuesRead, 2)
        XCTAssertEqual(draft.rowsSkipped, 3)
        XCTAssertEqual(draft.skippedRows.count, 3)
        XCTAssertTrue(draft.skippedRows[0].hasPrefix("CRP negativ"))
        XCTAssertTrue(draft.skippedRows[2].hasPrefix("Homocystein"))
    }

    func testASymbolAfterANameIsNotPartOfTheName() throws {
        // "<" normalises to nothing, so "CRP <" once matched as the name and the "<" was lost. Now the sign stays with
        // the number as a limit.
        let cases: [(String, LabMarkerKey, LabValueComparator, String)] = [
            ("CRP < 0,3 mg/l", .crp, .lessThan, "0.3"),
            ("CRP <0,3 mg/l", .crp, .lessThan, "0.3"),
            ("Kreatinin > 9 mg/dl", .creatinine, .greaterThan, "9"),
            ("ALT ≤ 5 U/l", .alt, .lessThanOrEqual, "5")
        ]
        for (row, key, sign, number) in cases {
            let draft = parse([row])
            XCTAssertTrue(draft.skippedRows.isEmpty, row)
            let value = try XCTUnwrap(markerValue(draft, key), row)
            XCTAssertEqual(value.comparator, sign, row)
            XCTAssertEqual(value.value, dec(number), row)
        }
    }

    // MARK: Results printed as a limit

    func testAResultBelowDetectionKeepsItsSignAndPrintsAsTheLabPrintedIt() throws {
        let draft = parse(["Albumin 4.6 g/dL 3.5 - 5.2", "hs-CRP <0.3 mg/L <3.0", "Apolipoprotein B >200 mg/dL <90 H"])
        XCTAssertEqual(draft.rowsSkipped, 0)
        let crp = try XCTUnwrap(markerValue(draft, .crp))
        XCTAssertEqual(crp.comparator, .lessThan)
        XCTAssertEqual(crp.value, dec("0.3"))
        XCTAssertEqual(crp.printedText, "<0.3")
        XCTAssertEqual(crp.unit, "mg/L")
        XCTAssertEqual(crp.referenceRange.text, "<3.0")
        XCTAssertFalse(crp.needsReview)

        let apob = try XCTUnwrap(markerValue(draft, .apoB))
        XCTAssertEqual(apob.comparator, .greaterThan)
        XCTAssertEqual(apob.value, dec("200"))
        XCTAssertEqual(apob.printedText, ">200")
        XCTAssertEqual(apob.flagText, "H")

        // An exact result has no sign.
        XCTAssertNil(try XCTUnwrap(markerValue(draft, .albumin)).comparator)
    }

    func testASignWithASpaceAndTheTwoCharacterSignsRead() throws {
        let spaced = try XCTUnwrap(markerValue(parse(["CRP < 0.3 mg/L"]), .crp))
        XCTAssertEqual(spaced.comparator, .lessThan)
        let atMost = try XCTUnwrap(markerValue(parse(["CRP <=0.3 mg/L"]), .crp))
        XCTAssertEqual(atMost.comparator, .lessThanOrEqual)
        XCTAssertEqual(atMost.printedText, "≤0.3")
        let atLeast = try XCTUnwrap(markerValue(parse(["Ferritin ≥ 1500 ng/mL"]), .ferritin))
        XCTAssertEqual(atLeast.comparator, .greaterThanOrEqual)
    }

    func testTheSignSplitsOffTypedText() {
        XCTAssertEqual(LabValueComparator.split("<0.3").comparator, .lessThan)
        XCTAssertEqual(LabValueComparator.split("<0.3").rest, "0.3")
        XCTAssertEqual(LabValueComparator.split(" > 200 ").comparator, .greaterThan)
        XCTAssertEqual(LabValueComparator.split(" > 200 ").rest, "200")
        XCTAssertEqual(LabValueComparator.split("≤5").comparator, .lessThanOrEqual)
        XCTAssertEqual(LabValueComparator.split(">=5").comparator, .greaterThanOrEqual)
        XCTAssertNil(LabValueComparator.split("5.4").comparator)
        XCTAssertEqual(LabValueComparator.split("5.4").rest, "5.4")
    }

    // MARK: Flags, units and why a value needs a look

    func testTheLabsFlagAndUnitStayOnTheValue() throws {
        let draft = parse(["Glucose 88 mg/dL 70 - 99", "Apolipoprotein B 112 H mg/dL <90", "Ferritin 412* ng/mL 30 - 400",
                           "Albumin 46 g/L L 35 - 52"])
        let glucose = try XCTUnwrap(markerValue(draft, .glucose))
        XCTAssertEqual(glucose.unit, "mg/dL")
        XCTAssertNil(glucose.flagText)
        let apob = try XCTUnwrap(markerValue(draft, .apoB))
        XCTAssertEqual(apob.flagText, "H")
        XCTAssertEqual(apob.unit, "mg/dL")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .ferritin)).flagText, "*")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .albumin)).flagText, "L")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .albumin)).unit, "g/L")
    }

    func testEachValueThatNeedsALookSaysWhy() throws {
        let draft = parse(["Kreatinin 0,5 mg/dl", "Thrombozyten 1.250 /nl", "Albumin 46 35 - 52", "HDL-Cholesterin 1,5 g/l >0,4",
                           "Harnsäure 5,O mg/dl"])
        func reasons(_ key: LabMarkerKey) throws -> [LabReviewReason] {
            draft.reviewReasons[try XCTUnwrap(markerValue(draft, key)).id] ?? []
        }
        XCTAssertEqual(try reasons(.creatinine), [])
        XCTAssertEqual(try reasons(.platelets), [.separatorUnclear])
        XCTAssertEqual(try reasons(.albumin), [.unitMissing])
        XCTAssertEqual(try reasons(.hdlCholesterol), [.unitUnknown])
        XCTAssertEqual(try reasons(.uricAcid), [.letterReadAsZero])
        XCTAssertEqual(draft.printedNames[try XCTUnwrap(markerValue(draft, .uricAcid)).id], "Harnsäure")
        // A value with a reason needs a look, and only those.
        for value in draft.values { XCTAssertEqual(value.needsReview, draft.reviewReasons[value.id] != nil, value.subject.displayName) }

        let faint = parse(["Albumin 46 g/l 35 - 52"], confidence: 0.4)
        XCTAssertEqual(faint.reviewReasons[try XCTUnwrap(faint.values.first).id], [.faintRow])
    }

    func testAKnownNameWithNothingAfterItIsNotARow() {
        let draft = parse(["Glucose tolerance test", "Albumin"])
        XCTAssertTrue(draft.values.isEmpty)
        XCTAssertEqual(draft.rowsSkipped, 0)
    }

    // MARK: Two tests on one row

    func testTwoTestsSideBySideOnOneLineBothRead() throws {
        let draft = parse(["Kreatinin 0,9 mg/dl 0,6 - 1,1 Glukose 90 mg/dl 70 - 99"])
        XCTAssertEqual(draft.values.count, 2)
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .creatinine)).referenceRange.high, dec("1.1"))
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .glucose)).value, dec("90"))
        let unknownSecond = parse(["Kreatinin 0,9 mg/dl 0,6 - 1,1 Selen 95 µg/l 70 - 150"])
        XCTAssertEqual(unknownSecond.values.count, 2)
        XCTAssertNotNil(otherValue(unknownSecond, "Selen"))
    }

    // MARK: Confidence

    func testScanConfidenceIsTheLowestOnTheRowAndLowConfidenceNeedsALook() throws {
        func row(_ confidences: [Double]) -> [LabTextLine] {
            let cells = [("Kreatinin", 0.05), ("0,9", 0.30), ("mg/dl", 0.40), ("0,6 - 1,1", 0.55)]
            return zip(cells, confidences).map { cell, confidence in
                LabTextLine(text: cell.0, minX: cell.1, minY: 0.9, width: 0.08, height: 0.015, confidence: confidence)
            }
        }
        let clear = try XCTUnwrap(parse(lines: row([0.99, 0.97, 0.95, 0.9])).values.first)
        XCTAssertEqual(clear.scanConfidence, 0.9)
        XCTAssertFalse(clear.needsReview)
        XCTAssertEqual(clear.source, .scan)

        let weak = try XCTUnwrap(parse(lines: row([0.99, 0.5, 0.95, 0.9])).values.first)
        XCTAssertEqual(weak.scanConfidence, 0.5)
        XCTAssertTrue(weak.needsReview)

        let edge = try XCTUnwrap(parse(lines: row([0.6, 0.6, 0.6, 0.6])).values.first)
        XCTAssertFalse(edge.needsReview, "the threshold is a strict less-than")

        let strict = LabReportParser.parse(lines: row([0.99, 0.8, 0.95, 0.9]), capturedAt: capturedAt, timeZone: berlin,
                                           options: .init(lowConfidenceThreshold: 0.85))
        XCTAssertTrue(try XCTUnwrap(strict.values.first).needsReview)
    }

    func testEveryValueIsAValidScannedValue() throws {
        let draft = parse(lines: try fixtureLines("noisy-report"))
        for read in draft.values {
            XCTAssertNoThrow(try read.validate())
            XCTAssertEqual(read.source, .scan)
            XCTAssertNotNil(read.scanConfidence)
            XCTAssertEqual(read.reportID, draft.report.id)
        }
    }

    func testIdsComeFromTheCallerSoTheDraftIsDeterministic() {
        let reportID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!
        var counter = 0
        let draft = LabReportParser.parse(lines: rows(["Albumin 46 g/l", "Ferritin 96 µg/l"]), capturedAt: capturedAt, timeZone: berlin,
                                          reportID: reportID, makeValueID: {
            counter += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
        })
        XCTAssertEqual(draft.report.id, reportID)
        XCTAssertEqual(draft.values.map(\.id.uuidString), ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"])
    }
}

final class LabReportHeaderTests: XCTestCase {
    private let result = "Kreatinin 0,9 mg/dl"

    func testCollectionDateForms() {
        let cases: [(String, Date)] = [
            ("Datum: 12.09.2026", berlinDate(2026, 9, 12)),
            ("Datum: 12.09.26", berlinDate(2026, 9, 12)),
            ("Eingangsdatum 12.09.2026", berlinDate(2026, 9, 12)),
            ("Collected: 2026-09-12", berlinDate(2026, 9, 12)),
            ("Collected: September 12, 2026 08:15", berlinDate(2026, 9, 12, 8, 15)),
            ("Collected: Sep 12 2026", berlinDate(2026, 9, 12)),
            ("Probenentnahme: 12.09.2026 08:15", berlinDate(2026, 9, 12, 8, 15)),
            ("Probenentnahme: 12.09.2026 um 08:15 Uhr", berlinDate(2026, 9, 12, 8, 15)),
            ("Probenentnahme: 12. September 2026", berlinDate(2026, 9, 12)),
            ("Abnahme 12 Sept. 2026", berlinDate(2026, 9, 12)),
            ("Entnahmedatum: 12 März 2026", berlinDate(2026, 3, 12)),
            ("Collected: 13/09/2026", berlinDate(2026, 9, 13)),
            ("Date collected: 09/13/2026", berlinDate(2026, 9, 13)),
            ("Specimen collected 2026-09-12 08:15", berlinDate(2026, 9, 12, 8, 15))
        ]
        for (row, expected) in cases {
            let draft = parse([row, result])
            XCTAssertTrue(draft.collectedDateFound, row)
            XCTAssertEqual(draft.report.collectedAt, expected, row)
            XCTAssertEqual(draft.report.timeZoneIdentifier, "Europe/Berlin")
            XCTAssertEqual(draft.report.source, .scan)
        }
    }

    func testDateLabelsAreKeptAsPrinted() {
        XCTAssertEqual(parse(["Probenentnahme: 12.09.2026", result]).collectedDateLabel, "Probenentnahme")
        XCTAssertEqual(parse(["Eingangsdatum: 12.09.2026", result]).collectedDateLabel, "Eingangsdatum")
        XCTAssertEqual(parse(["Datum: 12.09.2026", result]).collectedDateLabel, "Datum")
        XCTAssertEqual(parse(["Collected: 2026-09-12", result]).collectedDateLabel, "Collected")
    }

    func testCollectionBeatsReceiptAndReceiptBeatsABareDate() {
        XCTAssertEqual(parse(["Eingangsdatum: 13.09.2026", "Datum: 11.09.2026", "Probenentnahme: 12.09.2026", result]).report.collectedAt,
                       berlinDate(2026, 9, 12))
        XCTAssertEqual(parse(["Datum: 11.09.2026", "Eingangsdatum: 13.09.2026", result]).report.collectedAt, berlinDate(2026, 9, 13))
    }

    func testBirthDatesAndReportDatesAreNeverTheCollectionDate() {
        for header in [["Geburtsdatum: 03.04.1985"], ["Date of birth: 03.04.1985"], ["Befunddatum: 13.09.2026"], ["Report date: 2026-09-13"],
                       ["Geburtsdatum: 03.04.1985", "Befunddatum: 13.09.2026"]] {
            let draft = parse(header + [result])
            XCTAssertFalse(draft.collectedDateFound, "\(header)")
            XCTAssertEqual(draft.report.collectedAt, capturedAt)
        }
    }

    func testADateThatCannotBeReadWithoutGuessingIsNotUsed() {
        for row in ["Collected: 12/09/2026", "Datum: 31.02.2026", "Collected: 2026-12-01", "Datum: 12.09", "Datum: heute"] {
            let draft = parse([row, result])
            XCTAssertFalse(draft.collectedDateFound, row)
            XCTAssertEqual(draft.report.collectedAt, capturedAt, row)
            XCTAssertNil(draft.collectedDateLabel, row)
        }
    }

    func testLabNameForms() {
        XCTAssertEqual(parse(["Labor: Muster Labor GmbH", result]).report.labName, "Muster Labor GmbH")
        XCTAssertEqual(parse(["Laboratory: Acme Clinical Lab", result]).report.labName, "Acme Clinical Lab")
        XCTAssertEqual(parse(["Laborbefund", "Synlab Labor Nord", result]).report.labName, "Synlab Labor Nord")
        XCTAssertEqual(parse(["Quest Diagnostics", result]).report.labName, "Quest Diagnostics")
        XCTAssertEqual(parse(["Laboratory Report", "Acme Labs", result]).report.labName, "Acme Labs")
        XCTAssertEqual(parse(["MVZ Labor Beispielstadt", result]).report.labName, "MVZ Labor Beispielstadt")
        XCTAssertNil(parse(["Laborbefund", result]).report.labName)
        XCTAssertNil(parse([result, "Labor Berlin"]).report.labName, "a name below the first result is not a header")
        XCTAssertNil(parse([result]).report.labName)
    }

    func testFastingWhenPrinted() {
        XCTAssertEqual(parse(["Fasting sample", result]).report.fasting, true)
        XCTAssertEqual(parse(["Probe: nüchtern abgenommen", result]).report.fasting, true)
        XCTAssertEqual(parse(["Nüchtern: ja", result]).report.fasting, true)
        XCTAssertEqual(parse(["Nicht nüchtern", result]).report.fasting, false)
        XCTAssertEqual(parse(["Non-fasting", result]).report.fasting, false)
        XCTAssertEqual(parse(["Nüchtern: nein", result]).report.fasting, false)
        XCTAssertNil(parse([result]).report.fasting)
        XCTAssertNil(parse(["Glucose, fasting 88 mg/dL"]).report.fasting, "a test name is not a statement about the sample")
        XCTAssertNil(parse(["Glukose nüchtern 88 mg/dl"]).report.fasting)
    }
}

final class LabReportFixtureTests: XCTestCase {
    func testTheEnglishReport() throws {
        let draft = parse(lines: try fixtureLines("en-report"))
        XCTAssertEqual(draft.report.labName, "Sample Diagnostics Laboratory")
        XCTAssertEqual(draft.report.fasting, true)
        XCTAssertEqual(draft.report.collectedAt, berlinDate(2026, 9, 12, 8, 15))
        XCTAssertEqual(draft.report.collectedDay, "2026-09-12")
        XCTAssertEqual(draft.collectedDateLabel, "Collected")
        XCTAssertTrue(draft.collectedDateFound)
        XCTAssertEqual(draft.report.source, .scan)

        XCTAssertEqual(draft.valuesRead, 30)
        XCTAssertEqual(draft.valuesNeedingReview, 1)
        XCTAssertEqual(draft.rowsSkipped, 0)

        let apob = try XCTUnwrap(markerValue(draft, .apoB))
        XCTAssertEqual(apob.value, dec("112"))
        XCTAssertEqual(apob.unit, "mg/dL")
        XCTAssertEqual(apob.flagText, "H")
        XCTAssertEqual(apob.referenceRange.text, "<90")

        let crp = try XCTUnwrap(markerValue(draft, .crp))
        XCTAssertEqual(crp.assay, "hs-CRP")
        XCTAssertEqual(crp.value, dec("0.6"))
        XCTAssertEqual(crp.referenceRange.text, "<3.0")

        let wbc = try XCTUnwrap(markerValue(draft, .whiteBloodCellCount))
        XCTAssertEqual(wbc.unit, "x10E3/uL")
        XCTAssertEqual(wbc.referenceRange.low, dec("3.4"))
        XCTAssertEqual(wbc.referenceRange.high, dec("10.8"))

        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .vitaminD)).printedValue, "41.0")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .uricAcid)).printedValue, "5.0")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .tsh)).printedValue, "1.90")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .ferritin)).flagText, "*")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .egfr)).referenceRange.text, ">60")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .egfr)).unit, "mL/min/1.73m2")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .lymphocytePercent)).unit, "%")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .lipoproteinA)).value, dec("38"))

        let b12 = try XCTUnwrap(otherValue(draft, "Vitamin B12, Active"))
        XCTAssertEqual(b12.unit, "pmol/L")
        let testosterone = try XCTUnwrap(otherValue(draft, "Free Testosterone"))
        XCTAssertNil(testosterone.unit)
        XCTAssertTrue(testosterone.needsReview)
        XCTAssertEqual(draft.values.filter(\.needsReview).map(\.subject), [.other(name: "Free Testosterone")])
    }

    func testTheGermanReport() throws {
        let draft = parse(lines: try fixtureLines("de-report"))
        XCTAssertEqual(draft.report.labName, "MVZ Labor Beispielstadt")
        XCTAssertEqual(draft.report.fasting, true)
        XCTAssertEqual(draft.report.collectedAt, berlinDate(2026, 9, 12, 8, 15))
        XCTAssertEqual(draft.collectedDateLabel, "Probenentnahme")
        XCTAssertEqual(draft.valuesRead, 29)
        XCTAssertEqual(draft.valuesNeedingReview, 0)
        XCTAssertEqual(draft.rowsSkipped, 0)

        let creatinine = try XCTUnwrap(markerValue(draft, .creatinine))
        XCTAssertEqual(creatinine.value, dec("0.82"))
        XCTAssertEqual(creatinine.unit, "mg/dl")
        XCTAssertEqual(creatinine.referenceRange.low, dec("0.6"))
        XCTAssertEqual(creatinine.referenceRange.high, dec("1.2"))

        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .glucose)).referenceRange.high, dec("99"))
        let albumin = try XCTUnwrap(markerValue(draft, .albumin))
        XCTAssertEqual(albumin.value, dec("46.2"))
        XCTAssertEqual(albumin.unit, "g/l")
        XCTAssertEqual(albumin.referenceRange.low, dec("35"))
        XCTAssertEqual(albumin.referenceRange.high, dec("52"))
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .crp)).assay, "hs-CRP")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .crp)).referenceRange.text, "<3,0")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .lymphocytePercent)).printedValue, "31.0")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .whiteBloodCellCount)).unit, "/nl")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .hba1c)).unit, "mmol/mol")
        let apob = try XCTUnwrap(markerValue(draft, .apoB))
        XCTAssertEqual(apob.value, dec("1.12"))
        XCTAssertEqual(apob.flagText, "H")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .vitaminD)).printedValue, "41.0")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .ast)).value, dec("24"))
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .alt)).value, dec("22"))
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .egfr)).unit, "ml/min/1,73m²")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .platelets)).unit, "Tsd./µl")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .fastingInsulin)).unit, "µU/ml")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .totalCholesterol)).referenceRange.text, "<200")

        let microalbumin = try XCTUnwrap(otherValue(draft, "Mikroalbumin"))
        XCTAssertEqual(microalbumin.referenceRange.text, "negativ")
        XCTAssertEqual(microalbumin.unit, "mg/l")
    }

    func testTheGermanReportStoresNoCommaInAnyNumber() throws {
        let draft = parse(lines: try fixtureLines("de-report"))
        for read in draft.values {
            XCTAssertFalse(read.displayValue.contains(","), read.subject.displayName)
            XCTAssertFalse("\(read.value)".contains(","))
            XCTAssertFalse(read.referenceRange.low.map { "\($0)" }?.contains(",") ?? false)
        }
    }

    func testTheNoisyReport() throws {
        let draft = parse(lines: try fixtureLines("noisy-report"))
        XCTAssertEqual(draft.report.labName, "Beispiel Labor GmbH")
        XCTAssertEqual(draft.report.fasting, false)
        XCTAssertTrue(draft.collectedDateFound)
        XCTAssertEqual(draft.collectedDateLabel, "Datum")
        XCTAssertEqual(draft.report.collectedAt, berlinDate(2026, 9, 12))

        XCTAssertEqual(draft.valuesRead, 17)
        XCTAssertEqual(draft.valuesNeedingReview, 8)
        XCTAssertEqual(draft.rowsSkipped, 1)
        XCTAssertTrue(draft.skippedRows.contains { $0.hasPrefix("Homocystein") })
        // "<0,3" is read as a limit with its sign.
        let crp = try XCTUnwrap(markerValue(draft, .crp))
        XCTAssertEqual(crp.comparator, .lessThan)
        XCTAssertEqual(crp.value, dec("0.3"))
        XCTAssertEqual(crp.referenceRange.text, "<5")

        // O read as 0, flagged for a look.
        let creatinine = try XCTUnwrap(markerValue(draft, .creatinine))
        XCTAssertEqual(creatinine.value, dec("0.9"))
        XCTAssertTrue(creatinine.needsReview)
        XCTAssertEqual(creatinine.referenceRange.low, dec("0.6"))
        let glucose = try XCTUnwrap(markerValue(draft, .glucose))
        XCTAssertEqual(glucose.value, dec("90"))
        XCTAssertTrue(glucose.needsReview)
        let uric = try XCTUnwrap(markerValue(draft, .uricAcid))
        XCTAssertEqual(uric.value, dec("5"))
        XCTAssertEqual(uric.printedValue, "5.0")
        XCTAssertTrue(uric.needsReview)
        let ldl = try XCTUnwrap(markerValue(draft, .ldlCholesterol))
        XCTAssertEqual(ldl.value, dec("120"))
        XCTAssertTrue(ldl.needsReview)

        // The two columns both read.
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .albumin)).value, dec("4.6"))
        XCTAssertFalse(try XCTUnwrap(markerValue(draft, .albumin)).needsReview)

        // A name wrapped over two lines, and a name above its value.
        let alp = try XCTUnwrap(markerValue(draft, .alkalinePhosphatase))
        XCTAssertEqual(alp.value, dec("72"))
        XCTAssertEqual(alp.referenceRange.high, dec("129"))
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .tsh)).value, dec("1.9"))
        let lpa = try XCTUnwrap(markerValue(draft, .lipoproteinA))
        XCTAssertEqual(lpa.value, dec("38"))
        XCTAssertEqual(lpa.unit, "nmol/l")
        XCTAssertEqual(lpa.referenceRange.text, "<75")
        XCTAssertEqual(try XCTUnwrap(markerValue(draft, .ferritin)).value, dec("96"))

        // Unit missing, and a unit the marker is not reported in.
        let hemoglobin = try XCTUnwrap(markerValue(draft, .hemoglobin))
        XCTAssertNil(hemoglobin.unit)
        XCTAssertTrue(hemoglobin.needsReview)
        XCTAssertEqual(hemoglobin.referenceRange.high, dec("17.5"))
        let hdl = try XCTUnwrap(markerValue(draft, .hdlCholesterol))
        XCTAssertNil(hdl.unit)
        XCTAssertTrue(hdl.needsReview)
        XCTAssertEqual(hdl.referenceRange.text, ">0,4")

        // Unknown tests.
        let b12 = try XCTUnwrap(otherValue(draft, "Vitamin B12"))
        XCTAssertNil(b12.unit)
        XCTAssertTrue(b12.needsReview)
        let selen = try XCTUnwrap(otherValue(draft, "Selen"))
        XCTAssertEqual(selen.unit, "µg/l")
        XCTAssertFalse(selen.needsReview)

        // Low recognition confidence.
        let triglycerides = try XCTUnwrap(markerValue(draft, .triglycerides))
        XCTAssertEqual(triglycerides.scanConfidence, 0.45)
        XCTAssertTrue(triglycerides.needsReview)
        XCTAssertFalse(try XCTUnwrap(markerValue(draft, .platelets)).needsReview)
        XCTAssertFalse(try XCTUnwrap(markerValue(draft, .whiteBloodCellCount)).needsReview)

        // Noise is not a value.
        XCTAssertFalse(draft.values.contains { $0.subject.displayName.contains("Seite") })
    }

    func testTheCountsDriveThePanelLine() throws {
        let draft = parse(lines: try fixtureLines("noisy-report"))
        XCTAssertEqual(draft.valuesRead, draft.values.count)
        XCTAssertEqual(draft.valuesNeedingReview, draft.values.filter(\.needsReview).count)
        XCTAssertEqual(draft.rowsSkipped, draft.skippedRows.count)
        XCTAssertEqual("\(draft.valuesRead) values read, \(draft.valuesNeedingReview) need a look", "17 values read, 8 need a look")
    }
}
