import AnalyticsKit
import XCTest

final class LabMarkerCatalogTests: XCTestCase {
    func testEveryKeyHasOneMarkerWithItsOwnKey() {
        XCTAssertEqual(LabMarkerCatalog.markers.count, LabMarkerKey.allCases.count)
        XCTAssertEqual(Set(LabMarkerCatalog.markers.map(\.key)), Set(LabMarkerKey.allCases))
        for key in LabMarkerKey.allCases { XCTAssertEqual(key.marker.key, key) }
    }

    func testKeysAndDisplayNamesAreUnique() {
        XCTAssertEqual(Set(LabMarkerKey.allCases.map(\.rawValue)).count, LabMarkerKey.allCases.count)
        let names = LabMarkerCatalog.markers.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testDurableKeysDoNotChange() {
        // These strings are stored in the database. Renaming one orphans every value saved under it.
        XCTAssertEqual(LabMarkerKey.crp.rawValue, "crp")
        XCTAssertEqual(LabMarkerKey.apoB.rawValue, "apob")
        XCTAssertEqual(LabMarkerKey.lipoproteinA.rawValue, "lpa")
        XCTAssertEqual(LabMarkerKey.vitaminD.rawValue, "vitamin-d-25-hydroxy") // gitleaks:allow
        XCTAssertEqual(LabMarkerKey.whiteBloodCellCount.rawValue, "white-blood-cell-count")
        XCTAssertEqual(LabMarkerCatalog.marker(forRawKey: "hba1c")?.key, .hba1c)
        XCTAssertNil(LabMarkerCatalog.marker(forRawKey: "not-a-marker"))
    }

    func testTheNinePhenoAgeInputsAreFlagged() {
        let expected: Set<LabMarkerKey> = [
            .albumin, .creatinine, .glucose, .crp, .lymphocytePercent, .meanCellVolume,
            .redCellDistributionWidth, .alkalinePhosphatase, .whiteBloodCellCount
        ]
        XCTAssertEqual(Set(LabMarkerCatalog.phenoAgeInputs.map(\.key)), expected)
        XCTAssertEqual(LabMarkerCatalog.phenoAgeInputs.count, 9)
    }

    func testTheTrackedMarkersAreCovered() {
        let tracked: [LabMarkerKey] = [
            .apoB, .hba1c, .ldlCholesterol, .hdlCholesterol, .triglycerides, .totalCholesterol, .lipoproteinA,
            .fastingInsulin, .ferritin, .vitaminD, .tsh, .alt, .ast, .ggt, .egfr, .uricAcid, .hemoglobin,
            .platelets, .homocysteine
        ]
        for key in tracked { XCTAssertFalse(key.marker.isPhenoAgeInput, key.rawValue) }
        XCTAssertEqual(LabMarkerKey.allCases.count, tracked.count + 9)
    }

    func testEveryMarkerHasUnitsWithTheCanonicalUnitFirstAndNoRepeats() {
        for marker in LabMarkerCatalog.markers {
            XCTAssertFalse(marker.units.isEmpty, marker.key.rawValue)
            XCTAssertEqual(marker.canonicalUnit, marker.units.first)
            XCTAssertEqual(Set(marker.units).count, marker.units.count, marker.key.rawValue)
        }
        XCTAssertEqual(LabMarkerKey.apoB.marker.units, ["mg/dL", "g/L"])
        XCTAssertEqual(LabMarkerKey.lipoproteinA.marker.units, ["nmol/L", "mg/dL"])
    }

    func testEveryBodySystemHasMarkersAndTheStarMapListsEveryMarkerOnce() {
        for system in LabBodySystem.allCases { XCTAssertFalse(LabMarkerCatalog.markers(in: system).isEmpty, system.rawValue) }
        let grouped = LabBodySystem.allCases.flatMap { LabMarkerCatalog.markers(in: $0) }
        XCTAssertEqual(grouped.count, LabMarkerCatalog.markers.count)
    }

    func testCopyIsSentenceCaseWithoutExclamationMarksOrEmDashes() {
        let texts = LabMarkerCatalog.markers.map(\.displayName) + LabBodySystem.allCases.map(\.displayName)
        for text in texts {
            XCTAssertFalse(text.contains("!"), text)
            XCTAssertFalse(text.contains("\u{2014}"), text)
            XCTAssertFalse(text.hasPrefix(" ") || text.hasSuffix(" "), text)
        }
    }
}

final class LabModelTests: XCTestCase {
    private let reportID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    private func value(source: LabEntrySource = .typed, confidence: Double? = nil, review: Bool = false,
                       subject: LabValueSubject = .marker(.apoB)) -> LabValue {
        LabValue(reportID: reportID, subject: subject, value: Decimal(string: "78")!, unit: "mg/dL",
                 source: source, scanConfidence: confidence, needsReview: review)
    }

    func testTheCollectedDayFollowsTheReportsOwnTimeZone() {
        // 2026-09-11 23:30 UTC is already 12 September in Berlin and still 11 September in UTC.
        let instant = Date(timeIntervalSince1970: 1_789_169_400)
        let berlin = LabReport(collectedAt: instant, timeZoneIdentifier: "Europe/Berlin", source: .typed, createdAt: instant)
        let utc = LabReport(collectedAt: instant, timeZoneIdentifier: "UTC", source: .typed, createdAt: instant)
        XCTAssertEqual(berlin.collectedDay, "2026-09-12")
        XCTAssertEqual(utc.collectedDay, "2026-09-11")
    }

    func testAnUnknownTimeZoneIsRefused() {
        let report = LabReport(collectedAt: Date(timeIntervalSince1970: 0), timeZoneIdentifier: "Mars/Olympus", source: .typed, createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertNil(report.collectedDay)
        XCTAssertThrowsError(try report.validate()) { XCTAssertEqual($0 as? LabValidationError, .unknownTimeZone("Mars/Olympus")) }
    }

    func testAReferenceRangeIsEmptyUntilTheLabPrintedOne() {
        XCTAssertTrue(LabReferenceRange.none.isEmpty)
        XCTAssertFalse(LabReferenceRange(text: "<5.0").isEmpty)
        XCTAssertFalse(LabReferenceRange(low: Decimal(string: "0.5")!).isEmpty)
        XCTAssertTrue(value().referenceRange.isEmpty)
        XCTAssertNil(value().flagText)
    }

    func testTypedValuesCarryNoScanFields() {
        XCTAssertNoThrow(try value().validate())
        XCTAssertThrowsError(try value(confidence: 0.9).validate()) { XCTAssertEqual($0 as? LabValidationError, .typedValueCarriesScanFields) }
        XCTAssertThrowsError(try value(review: true).validate()) { XCTAssertEqual($0 as? LabValidationError, .typedValueCarriesScanFields) }
        XCTAssertNoThrow(try value(source: .scan, confidence: 0.58, review: true).validate())
    }

    func testScanConfidenceStaysBetweenZeroAndOne() {
        XCTAssertNoThrow(try value(source: .scan, confidence: 0).validate())
        XCTAssertNoThrow(try value(source: .scan, confidence: 1).validate())
        XCTAssertThrowsError(try value(source: .scan, confidence: 1.01).validate()) { XCTAssertEqual($0 as? LabValidationError, .scanConfidenceOutOfRange) }
        XCTAssertThrowsError(try value(source: .scan, confidence: -0.1).validate())
    }

    func testAnOtherValueKeepsTheLabsNameAndNeedsOne() {
        let other = value(subject: .other(name: "Vitamin B12 aktiv"))
        XCTAssertEqual(other.subject.displayName, "Vitamin B12 aktiv")
        XCTAssertNil(other.subject.markerKey)
        XCTAssertNoThrow(try other.validate())
        XCTAssertThrowsError(try value(subject: .other(name: "  ")).validate()) { XCTAssertEqual($0 as? LabValidationError, .blankName) }
    }

    func testHsCrpAndCrpShareOneMarkerAndTheAssayRidesOnTheValue() {
        let hs = LabValue(reportID: reportID, subject: .marker(.crp), assay: "hs-CRP", value: Decimal(string: "0.6")!, unit: "mg/L", source: .typed)
        let plain = LabValue(reportID: reportID, subject: .marker(.crp), assay: "CRP", value: Decimal(string: "3")!, unit: "mg/L", source: .typed)
        XCTAssertEqual(hs.subject, plain.subject)
        XCTAssertNotEqual(hs.assay, plain.assay)
        XCTAssertEqual(hs.subject.displayName, "C-reactive protein")
    }

    func testClockResultsNeedALabNameAndNeedNoUnit() {
        let at = Date(timeIntervalSince1970: 1_789_000_000)
        let pace = LabClockResult(kind: .dunedinPACE, value: Decimal(string: "0.92")!, labName: "TruDiagnostic", collectedAt: at, timeZoneIdentifier: "UTC", createdAt: at)
        XCTAssertNil(pace.unit)
        XCTAssertEqual(pace.kind.displayName, "DunedinPACE")
        XCTAssertEqual(LabClockKind.grimAge.displayName, "GrimAge")
        XCTAssertNoThrow(try pace.validate())
        var unnamed = pace
        unnamed.labName = "  "
        XCTAssertThrowsError(try unnamed.validate()) { XCTAssertEqual($0 as? LabValidationError, .blankLabName) }
        var other = pace
        other.kind = .other(name: "")
        XCTAssertThrowsError(try other.validate()) { XCTAssertEqual($0 as? LabValidationError, .blankName) }
    }

    func testTypedTrailingZerosArePreservedAsThePrintedValue() throws {
        let parsed = try XCTUnwrap(LabNumberText.parse("5.0"))
        XCTAssertEqual(parsed.value, Decimal(string: "5")!)
        XCTAssertEqual(parsed.printedValue, "5.0")
        let plain = try XCTUnwrap(LabNumberText.parse("78.5"))
        XCTAssertNil(plain.printedValue)
        XCTAssertEqual(try XCTUnwrap(LabNumberText.parse(" 0.60 ")).printedValue, "0.60")
        XCTAssertEqual(try XCTUnwrap(LabNumberText.parse("-2.50")).value, Decimal(string: "-2.5")!)
        XCTAssertNil(try XCTUnwrap(LabNumberText.parse("-2.5")).printedValue)
    }

    func testNumberTextNeverGuessesASeparator() {
        for text in ["5,0", "1,234.5", "1.234,5", "", ".", "5.", ".5", "1e3", "5 0", "--1", "abc", "+5"] {
            XCTAssertNil(LabNumberText.parse(text), text)
        }
    }

    func testTheDisplayValueShowsThePrintedDigitsAndThePrintedValueMustMatchTheNumber() throws {
        let parsed = try XCTUnwrap(LabNumberText.parse("5.0"))
        var hba1c = LabValue(reportID: reportID, subject: .marker(.hba1c), value: parsed.value,
                             printedValue: parsed.printedValue, unit: "%", source: .typed)
        XCTAssertEqual(hba1c.displayValue, "5.0")
        XCTAssertNoThrow(try hba1c.validate())
        XCTAssertEqual(value().displayValue, "78")
        hba1c.printedValue = "5.1"
        XCTAssertThrowsError(try hba1c.validate()) { XCTAssertEqual($0 as? LabValidationError, .printedValueMismatch) }
        hba1c.printedValue = "5,0"
        XCTAssertThrowsError(try hba1c.validate()) { XCTAssertEqual($0 as? LabValidationError, .printedValueMismatch) }
    }
}
