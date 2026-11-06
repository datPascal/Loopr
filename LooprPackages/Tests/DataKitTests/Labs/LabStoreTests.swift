import AnalyticsKit
import DataKit
import StorageKit
import XCTest

final class LabStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func makeDatabase() throws -> StorageDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabStoreTests-\(UUID().uuidString)")
        roots.append(root)
        return try StorageDatabase(url: root.appendingPathComponent("labs.sqlite"), applicationVersion: "lab-store-tests")
    }

    private func dec(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    /// 12 September 2026, 08:15 in Berlin, plus whole days.
    private let drawn = Date(timeIntervalSince1970: 1_789_193_700)
    private func days(_ count: Double) -> Date { drawn.addingTimeInterval(count * 86_400) }

    private func makeReport(id: UUID = UUID(), collected: Date, created: Date? = nil, lab: String? = "Labor Berlin",
                        source: LabEntrySource = .typed) -> LabReport {
        LabReport(id: id, collectedAt: collected, timeZoneIdentifier: "Europe/Berlin", labName: lab, fasting: true,
                  source: source, createdAt: created ?? collected.addingTimeInterval(3_600), note: "Annual check")
    }

    private func makeValue(_ report: LabReport, _ subject: LabValueSubject, _ text: String, unit: String? = "mg/dL",
                       range: LabReferenceRange = .none) -> LabValue {
        LabValue(reportID: report.id, subject: subject, value: dec(text), unit: unit, referenceRange: range, source: .typed)
    }

    func testAReportAndItsValuesRoundTripWithTheLabsOwnWordsAndExactDigits() throws {
        let database = try makeDatabase()
        let store = LabStore(database: database)
        let report = makeReport(collected: drawn, source: .scan)
        let apob = LabValue(reportID: report.id, subject: .marker(.apoB), value: dec("78"), unit: "mg/dL",
            referenceRange: LabReferenceRange(low: dec("40"), high: dec("90")), source: .scan, scanConfidence: 0.97)
        let crp = LabValue(reportID: report.id, subject: .marker(.crp), assay: "hs-CRP", value: dec("0.6"), unit: "mg/L",
            referenceRange: LabReferenceRange(text: "<5.0"), flagText: "H", source: .scan, scanConfidence: 0.41, needsReview: true)
        let digits = LabValue(reportID: report.id, subject: .marker(.glucose), value: dec("1234567.891234"), unit: "mmol/L",
            referenceRange: LabReferenceRange(low: dec("3.9"), high: dec("5.5")), source: .typed)
        let negative = LabValue(reportID: report.id, subject: .other(name: "Base excess"), value: dec("-2.5"), unit: nil, source: .typed)
        try store.saveReport(report, values: [apob, crp, digits, negative])
        try database.databasePool.close()

        let reopened = try StorageDatabase(path: database.path, applicationVersion: "lab-store-tests")
        defer { try? reopened.databasePool.close() }
        let read = LabStore(database: reopened)
        XCTAssertEqual(try read.report(id: report.id), report)
        XCTAssertEqual(try read.reports(), [report])
        let values = try read.values(reportID: report.id)
        XCTAssertEqual(values, [apob, crp, digits, negative])
        XCTAssertEqual(values[2].value.description, "1234567.891234")
        XCTAssertEqual(values[1].referenceRange.text, "<5.0")
        XCTAssertEqual(values[1].assay, "hs-CRP")
        XCTAssertTrue(values[1].needsReview)
        XCTAssertEqual(values[1].scanConfidence, 0.41)
        XCTAssertNil(values[3].unit)
        XCTAssertTrue(values[3].referenceRange.isEmpty)
        XCTAssertNil(values[3].flagText)
        XCTAssertEqual(values[3].value, dec("-2.5"))
    }

    func testAResultPrintedAsALimitKeepsItsSignThroughSaveUpdateAndReopen() throws {
        let database = try makeDatabase()
        let store = LabStore(database: database)
        let report = makeReport(collected: drawn, source: .scan)
        let crp = LabValue(reportID: report.id, subject: .marker(.crp), value: dec("0.3"), comparator: .lessThan, unit: "mg/L",
                           referenceRange: LabReferenceRange(text: "<3.0"), source: .scan, scanConfidence: 0.9)
        let apob = LabValue(reportID: report.id, subject: .marker(.apoB), value: dec("200"), comparator: .greaterThan, unit: "mg/dL",
                            flagText: "H", source: .scan, scanConfidence: 0.9)
        try store.saveReport(report, values: [crp, apob])
        try database.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT comparator FROM lab_value ORDER BY position"), ["<", ">"])
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT value_text FROM lab_value ORDER BY position"), ["0.3", "200"])
        }
        var exact = crp
        exact.comparator = nil
        exact.value = dec("0.25")
        try store.updateValue(exact)
        try database.databasePool.close()

        let reopened = try StorageDatabase(path: database.path, applicationVersion: "lab-store-tests")
        defer { try? reopened.databasePool.close() }
        let values = try LabStore(database: reopened).values(reportID: report.id)
        XCTAssertEqual(values, [exact, apob])
        XCTAssertNil(values[0].comparator)
        XCTAssertEqual(values[1].printedText, ">200")
    }

    func testTheNextPageAddsToTheSameReportAfterItsValuesAndSkipsRepeats() throws {
        let database = try makeDatabase()
        let store = LabStore(database: database)
        let report = makeReport(collected: drawn, source: .scan)
        let albumin = makeValue(report, .marker(.albumin), "46", unit: "g/L")
        let glucose = makeValue(report, .marker(.glucose), "5.0", unit: "mmol/L")
        try store.saveReport(report, values: [albumin, glucose])

        // Page 2 repeats glucose from the page header and adds the blood count.
        let repeated = makeValue(report, .marker(.glucose), "5.0", unit: "mmol/L")
        let mcv = makeValue(report, .marker(.meanCellVolume), "89", unit: "fL")
        let rdw = makeValue(report, .marker(.redCellDistributionWidth), "12.9", unit: "%")
        let added = try store.appendValues([repeated, mcv, rdw], toReport: report.id)
        XCTAssertEqual(added, [mcv, rdw])
        XCTAssertEqual(try store.values(reportID: report.id), [albumin, glucose, mcv, rdw])
        XCTAssertEqual(try store.reports().count, 1)

        // A different number for the same test is not a repeat; it stays for the person to sort out.
        let other = makeValue(report, .marker(.glucose), "5.4", unit: "mmol/L")
        XCTAssertEqual(try store.appendValues([other], toReport: report.id), [other])

        let elsewhere = makeReport(collected: days(1))
        XCTAssertThrowsError(try store.appendValues([makeValue(elsewhere, .marker(.albumin), "45", unit: "g/L")], toReport: report.id))
        XCTAssertThrowsError(try store.appendValues([], toReport: UUID())) { error in
            XCTAssertEqual(error as? LabStoreError, .missingReport)
        }
    }

    func testNumbersAreStoredAsTextWithADotAndNeverAComma() throws {
        let database = try makeDatabase()
        let store = LabStore(database: database)
        let report = makeReport(collected: drawn)
        let value = LabValue(reportID: report.id, subject: .marker(.glucose), value: dec("5.25"), unit: "mmol/L",
            referenceRange: LabReferenceRange(low: dec("3.9"), high: dec("5.6")), source: .typed)
        try store.saveReport(report, values: [value])
        try database.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT value_text, reference_low, reference_high FROM lab_value"))
            XCTAssertEqual(row["value_text"] as String, "5.25")
            XCTAssertEqual(row["reference_low"] as String, "3.9")
            XCTAssertEqual(row["reference_high"] as String, "5.6")
        }
    }

    func testReportsListNewestCollectionFirst() throws {
        let store = LabStore(database: try makeDatabase())
        let old = makeReport(collected: days(-200))
        let recent = makeReport(collected: days(0))
        let middle = makeReport(collected: days(-90))
        for item in [middle, recent, old] { try store.saveReport(item, values: []) }
        XCTAssertEqual(try store.reports().map(\.id), [recent.id, middle.id, old.id])
    }

    func testAMarkersHistoryRunsOldestFirstAcrossReportsAndIgnoresOtherMarkers() throws {
        let store = LabStore(database: try makeDatabase())
        let first = makeReport(collected: days(-180), lab: "Lab A")
        let second = makeReport(collected: days(-90), lab: "Lab B")
        let third = makeReport(collected: days(0), lab: "Lab A")
        // Saved out of order on purpose.
        try store.saveReport(third, values: [makeValue(third, .marker(.ldlCholesterol), "96"), makeValue(third, .marker(.apoB), "70")])
        try store.saveReport(first, values: [makeValue(first, .marker(.ldlCholesterol), "121")])
        try store.saveReport(second, values: [makeValue(second, .marker(.ldlCholesterol), "104", unit: "mg/dL"),
                                              makeValue(second, .marker(.hdlCholesterol), "55")])
        let history = try store.history(for: .marker(.ldlCholesterol))
        XCTAssertEqual(history.map(\.value.value), [dec("121"), dec("104"), dec("96")])
        XCTAssertEqual(history.map(\.report.id), [first.id, second.id, third.id])
        XCTAssertEqual(history.map(\.report.labName), ["Lab A", "Lab B", "Lab A"])
        XCTAssertEqual(try store.history(for: .marker(.egfr)), [])
    }

    func testReportsCollectedTogetherBreakTiesByCreationTime() throws {
        let store = LabStore(database: try makeDatabase())
        let late = makeReport(collected: drawn, created: drawn.addingTimeInterval(7_200))
        let early = makeReport(collected: drawn, created: drawn.addingTimeInterval(3_600))
        try store.saveReport(late, values: [makeValue(late, .marker(.tsh), "2.1", unit: "mIU/L")])
        try store.saveReport(early, values: [makeValue(early, .marker(.tsh), "1.9", unit: "mIU/L")])
        XCTAssertEqual(try store.history(for: .marker(.tsh)).map(\.report.id), [early.id, late.id])
        XCTAssertEqual(try store.latestValues()[.marker(.tsh)]?.report.id, late.id)
    }

    func testValuesForMarkersOutsideTheCatalogAreKeptUnderTheLabsName() throws {
        let store = LabStore(database: try makeDatabase())
        let first = makeReport(collected: days(-30))
        let second = makeReport(collected: days(0))
        let named = LabValue(reportID: first.id, subject: .other(name: "Vitamin B12 aktiv"), value: dec("88"), unit: "pmol/L",
            referenceRange: LabReferenceRange(low: dec("37.5")), source: .typed)
        let again = LabValue(reportID: second.id, subject: .other(name: "vitamin b12 AKTIV"), value: dec("101"), unit: "pmol/L", source: .typed)
        try store.saveReport(first, values: [named, makeValue(first, .marker(.apoB), "80")])
        try store.saveReport(second, values: [again])

        let stored = try store.values(reportID: first.id)
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored[0].subject, .other(name: "Vitamin B12 aktiv"))
        XCTAssertEqual(stored[0].referenceRange.low, dec("37.5"))

        let history = try store.history(for: .other(name: "Vitamin B12 Aktiv"))
        XCTAssertEqual(history.map(\.value.value), [dec("88"), dec("101")])
        XCTAssertEqual(try store.history(for: .marker(.apoB)).count, 1)
        XCTAssertEqual(try store.latestValues()[.other(name: "vitamin b12 AKTIV")]?.value.value, dec("101"))
    }

    func testLatestValuePerMarkerComesFromTheNewestReportThatHasIt() throws {
        let store = LabStore(database: try makeDatabase())
        let old = makeReport(collected: days(-120))
        let recent = makeReport(collected: days(0))
        try store.saveReport(old, values: [makeValue(old, .marker(.apoB), "90"), makeValue(old, .marker(.ferritin), "60", unit: "ng/mL")])
        try store.saveReport(recent, values: [makeValue(recent, .marker(.apoB), "78")])
        let latest = try store.latestValues()
        XCTAssertEqual(Set(latest.keys), [.marker(.apoB), .marker(.ferritin)])
        XCTAssertEqual(latest[.marker(.apoB)]?.value.value, dec("78"))
        XCTAssertEqual(latest[.marker(.apoB)]?.report.id, recent.id)
        XCTAssertEqual(latest[.marker(.ferritin)]?.report.id, old.id)
    }

    func testUpdatingAValueKeepsItsReportAndPosition() throws {
        let store = LabStore(database: try makeDatabase())
        let report = makeReport(collected: drawn, source: .scan)
        let first = LabValue(reportID: report.id, subject: .marker(.apoB), value: dec("781"), unit: "mg/dL", source: .scan,
            scanConfidence: 0.4, needsReview: true)
        let second = makeValue(report, .marker(.hba1c), "5.2", unit: "%")
        try store.saveReport(report, values: [first, second])

        var fixed = first
        fixed.value = dec("78.1")
        fixed.needsReview = false
        fixed.flagText = "*"
        try store.updateValue(fixed)

        let values = try store.values(reportID: report.id)
        XCTAssertEqual(values.map(\.id), [first.id, second.id])
        XCTAssertEqual(values[0], fixed)
        XCTAssertEqual(values[0].source, .scan)
        XCTAssertEqual(try store.report(id: report.id), report)
    }

    func testUpdatingRefusesAMissingValueAndAValueFromAnotherReport() throws {
        let store = LabStore(database: try makeDatabase())
        let report = makeReport(collected: drawn)
        let stored = makeValue(report, .marker(.apoB), "78")
        try store.saveReport(report, values: [stored])

        XCTAssertThrowsError(try store.updateValue(makeValue(report, .marker(.apoB), "1"))) {
            XCTAssertEqual($0 as? LabStoreError, .missingValue)
        }
        var moved = stored
        moved.reportID = UUID()
        XCTAssertThrowsError(try store.updateValue(moved)) {
            XCTAssertEqual($0 as? LabValidationError, .valueBelongsToAnotherReport)
        }
        XCTAssertEqual(try store.values(reportID: report.id), [stored])
    }

    func testDeletingAReportDeletesItsValuesAndNoOtherReports() throws {
        let database = try makeDatabase()
        let store = LabStore(database: database)
        let drop = makeReport(collected: days(-10))
        let keep = makeReport(collected: days(0))
        try store.saveReport(drop, values: [makeValue(drop, .marker(.apoB), "80"), makeValue(drop, .other(name: "Selenium"), "110", unit: "µg/L")])
        try store.saveReport(keep, values: [makeValue(keep, .marker(.apoB), "78")])

        try store.deleteReport(id: drop.id)
        XCTAssertEqual(try store.reports(), [keep])
        XCTAssertEqual(try store.values(reportID: drop.id), [])
        XCTAssertEqual(try store.values(reportID: keep.id).count, 1)
        XCTAssertEqual(try database.tableRowCounts()["lab_value"], 1)
        XCTAssertEqual(try store.history(for: .other(name: "Selenium")), [])
        XCTAssertThrowsError(try store.deleteReport(id: drop.id)) { XCTAssertEqual($0 as? LabStoreError, .missingReport) }
    }

    func testSavingAReportAgainReplacesItsValues() throws {
        let store = LabStore(database: try makeDatabase())
        var report = makeReport(collected: drawn)
        try store.saveReport(report, values: [makeValue(report, .marker(.apoB), "78"), makeValue(report, .marker(.tsh), "2", unit: "mIU/L")])
        report.note = "Corrected"
        let replacement = makeValue(report, .marker(.ferritin), "55", unit: "ng/mL")
        try store.saveReport(report, values: [replacement])
        XCTAssertEqual(try store.reports(), [report])
        XCTAssertEqual(try store.values(reportID: report.id), [replacement])
    }

    func testASaveThatFailsWritesNothing() throws {
        let database = try makeDatabase()
        let store = LabStore(database: database)
        let kept = makeReport(collected: days(-5))
        let existing = makeValue(kept, .marker(.apoB), "80")
        try store.saveReport(kept, values: [existing])

        let broken = makeReport(collected: drawn)
        let clash = makeValue(broken, .marker(.hba1c), "5", unit: "%")
        // The second value reuses the id of a value in another report, so its insert fails after the first one went in.
        let clashing = LabValue(id: existing.id, reportID: broken.id, subject: .marker(.tsh), value: dec("2"), source: .typed)
        XCTAssertThrowsError(try store.saveReport(broken, values: [clash, clashing]))
        XCTAssertNil(try store.report(id: broken.id))
        XCTAssertEqual(try store.values(reportID: kept.id), [existing])

        var foreign = makeValue(broken, .marker(.tsh), "2")
        foreign.reportID = UUID()
        XCTAssertThrowsError(try store.saveReport(broken, values: [foreign])) {
            XCTAssertEqual($0 as? LabValidationError, .valueBelongsToAnotherReport)
        }
        XCTAssertNil(try store.report(id: broken.id))
        XCTAssertEqual(try database.tableRowCounts()["lab_report"], 1)
    }

    func testAMarkerKeyFromANewerBuildComesBackAsAnOtherValueInsteadOfBeingDropped() throws {
        let database = try makeDatabase()
        let store = LabStore(database: database)
        let report = makeReport(collected: drawn)
        try store.saveReport(report, values: [])
        try database.write { db in
            try db.execute(sql: "INSERT INTO lab_value(id, report_id, position, marker_key, value_text, source) VALUES (?, ?, 0, 'future-marker', '4.2', 'typed')",
                arguments: [UUID().uuidString, report.id.uuidString])
        }
        let values = try store.values(reportID: report.id)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].subject, .other(name: "future-marker"))
        XCTAssertEqual(values[0].value, dec("4.2"))
    }

    func testClockResultsKeepTheLabsNameAndListNewestFirst() throws {
        let store = LabStore(database: try makeDatabase())
        let pace = LabClockResult(kind: .dunedinPACE, value: dec("0.92"), labName: "TruDiagnostic",
            collectedAt: days(-60), timeZoneIdentifier: "America/New_York", createdAt: days(-59), note: "Saliva kit")
        let grim = LabClockResult(kind: .grimAge, value: dec("38.4"), unit: "years", labName: "Lab B",
            collectedAt: days(0), timeZoneIdentifier: "Europe/Berlin", createdAt: days(1))
        let other = LabClockResult(kind: .other(name: "Horvath"), value: dec("41"), unit: "years", labName: "Lab C",
            collectedAt: days(-30), timeZoneIdentifier: "UTC", createdAt: days(-29))
        for result in [other, pace, grim] { try store.saveClockResult(result) }

        let listed = try store.clockResults()
        XCTAssertEqual(listed, [grim, other, pace])
        XCTAssertEqual(listed[2].labName, "TruDiagnostic")
        XCTAssertNil(listed[2].unit)
        XCTAssertEqual(listed[1].kind, .other(name: "Horvath"))

        try store.deleteClockResult(id: other.id)
        XCTAssertEqual(try store.clockResults(), [grim, pace])
        XCTAssertThrowsError(try store.deleteClockResult(id: other.id)) { XCTAssertEqual($0 as? LabStoreError, .missingClockResult) }
    }

    func testAClockResultWithoutALabNameIsRefused() throws {
        let store = LabStore(database: try makeDatabase())
        let result = LabClockResult(kind: .grimAge, value: dec("40"), labName: "", collectedAt: drawn,
            timeZoneIdentifier: "UTC", createdAt: drawn)
        XCTAssertThrowsError(try store.saveClockResult(result)) { XCTAssertEqual($0 as? LabValidationError, .blankLabName) }
        XCTAssertEqual(try store.clockResults(), [])
    }

    func testAccountDeletionEmptiesEveryLabTableThroughTheStore() throws {
        let database = try makeDatabase()
        let store = LabStore(database: database)
        let report = makeReport(collected: drawn)
        try store.saveReport(report, values: [makeValue(report, .marker(.apoB), "78")])
        try store.saveClockResult(LabClockResult(kind: .grimAge, value: dec("40"), labName: "Lab", collectedAt: drawn,
            timeZoneIdentifier: "UTC", createdAt: drawn))
        for table in LabStorageSchema.tableNames { XCTAssertEqual(try database.tableRowCounts()[table], 1, table) }

        try database.deleteAllAccountData()
        XCTAssertEqual(try store.reports(), [])
        XCTAssertEqual(try store.clockResults(), [])
        XCTAssertEqual(try store.latestValues().count, 0)
        for table in LabStorageSchema.tableNames { XCTAssertEqual(try database.tableRowCounts()[table], 0, table) }
    }

    func testThePrintedValueSurvivesSaveUpdateAndReopen() throws {
        let database = try makeDatabase()
        let store = LabStore(database: database)
        let report = makeReport(collected: drawn)
        let parsed = try XCTUnwrap(LabNumberText.parse("5.0"))
        let hba1c = LabValue(reportID: report.id, subject: .marker(.hba1c), value: parsed.value,
            printedValue: parsed.printedValue, unit: "%", source: .typed)
        let plain = makeValue(report, .marker(.apoB), "78")
        try store.saveReport(report, values: [hba1c, plain])

        var stored = try store.values(reportID: report.id)
        XCTAssertEqual(stored[0].printedValue, "5.0")
        XCTAssertEqual(stored[0].displayValue, "5.0")
        XCTAssertEqual(stored[0].value, dec("5"))
        XCTAssertNil(stored[1].printedValue)
        XCTAssertEqual(stored[1].displayValue, "78")

        var edited = stored[0]
        edited.value = dec("5.20")
        edited.printedValue = "5.20"
        try store.updateValue(edited)
        stored = try store.values(reportID: report.id)
        XCTAssertEqual(stored[0].displayValue, "5.20")
        XCTAssertEqual(try store.history(for: .marker(.hba1c)).first?.value.printedValue, "5.20")

        edited.printedValue = "5.0"
        XCTAssertThrowsError(try store.updateValue(edited)) { XCTAssertEqual($0 as? LabValidationError, .printedValueMismatch) }
        XCTAssertEqual(try store.values(reportID: report.id)[0].displayValue, "5.20")
    }
}
