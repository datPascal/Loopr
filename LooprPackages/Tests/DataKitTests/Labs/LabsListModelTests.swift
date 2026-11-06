import AnalyticsKit
import DataKit
import StorageKit
import XCTest

final class LabsListModelTests: XCTestCase {
    private let berlin = "Europe/Berlin"
    /// 12 September 2026, 08:15 in Berlin.
    private let drawn = Date(timeIntervalSince1970: 1_789_193_700)
    private func days(_ count: Double) -> Date { drawn.addingTimeInterval(count * 86_400) }
    private func dec(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    private func report(_ collected: Date, lab: String? = "Labor Berlin", fasting: Bool? = true, source: LabEntrySource = .typed,
                        created: Date? = nil) -> LabReport {
        LabReport(collectedAt: collected, timeZoneIdentifier: berlin, labName: lab, fasting: fasting, source: source,
                  createdAt: created ?? collected.addingTimeInterval(60))
    }

    private func value(_ report: LabReport, _ key: LabMarkerKey, _ text: String, unit: String? = nil, review: Bool = false) -> LabValue {
        LabValue(reportID: report.id, subject: .marker(key), value: dec(text), unit: unit ?? key.marker.canonicalUnit,
                 source: review ? .scan : report.source, scanConfidence: review ? 0.5 : nil, needsReview: review)
    }

    func testReportsListNewestFirstWithCountsAndNeedsALookCounts() {
        let old = report(days(-90))
        let recent = report(drawn, source: .scan)
        let values = [value(old, .albumin, "46"), value(old, .hba1c, "5.4"),
                      value(recent, .albumin, "47", review: true), value(recent, .crp, "0.6", review: true),
                      value(recent, .glucose, "90")]
        let snapshot = LabsListSnapshot.make(reports: [old, recent], values: values, clockResults: [])
        XCTAssertEqual(snapshot.reports.map(\.id), [recent.id, old.id])
        XCTAssertEqual(snapshot.reports.map(\.valueCount), [3, 2])
        XCTAssertEqual(snapshot.reports.map(\.needsReviewCount), [2, 0])
        XCTAssertEqual(snapshot.reports[0].needsLookText, "2 need a look")
        XCTAssertNil(snapshot.reports[1].needsLookText)
        XCTAssertEqual(snapshot.valueTotal, 5)
        XCTAssertEqual(snapshot.needsLookTotal, 2)
        XCTAssertEqual(snapshot.summaryLine, "2 reports · 5 values")
        XCTAssertTrue(snapshot.hasResults)
    }

    func testOneNeedsLookAndTheSubtitleNamesLabValuesAndFasting() {
        let single = report(drawn, lab: "Labor Berlin", fasting: true)
        let snapshot = LabsListSnapshot.make(reports: [single], values: [value(single, .albumin, "46", review: true)], clockResults: [])
        XCTAssertEqual(snapshot.reports[0].needsLookText, "1 needs a look")
        XCTAssertEqual(snapshot.reports[0].subtitle, "Labor Berlin · 1 value · fasting")
        XCTAssertEqual(snapshot.reports[0].title, LabsDisplay.day(drawn, timeZoneIdentifier: berlin))
        XCTAssertEqual(LabsDisplay.day(drawn, timeZoneIdentifier: berlin, locale: Locale(identifier: "en_GB")), "12 Sep 2026")
        XCTAssertEqual(LabsDisplay.day(drawn, timeZoneIdentifier: berlin, locale: Locale(identifier: "en_US")), "Sep 12, 2026")
        let bare = report(drawn, lab: nil, fasting: nil)
        let bareSnapshot = LabsListSnapshot.make(reports: [bare], values: [], clockResults: [])
        XCTAssertEqual(bareSnapshot.reports[0].subtitle, "Lab not named · 0 values")
        let notFasting = report(drawn, lab: "Synlab", fasting: false)
        XCTAssertTrue(LabsListSnapshot.make(reports: [notFasting], values: [], clockResults: []).reports[0].subtitle.hasSuffix("not fasting"))
    }

    func testReportsCollectedTogetherListTheLaterCreatedFirstAndClocksSortNewestFirst() {
        let first = report(drawn, created: drawn.addingTimeInterval(10))
        let second = report(drawn, created: drawn.addingTimeInterval(20))
        let clockOld = LabClockResult(kind: .grimAge, value: 41, labName: "A", collectedAt: days(-200), timeZoneIdentifier: berlin, createdAt: days(-200))
        let clockNew = LabClockResult(kind: .dunedinPACE, value: dec("0.9"), labName: "B", collectedAt: days(-10), timeZoneIdentifier: berlin, createdAt: days(-10))
        let snapshot = LabsListSnapshot.make(reports: [first, second], values: [], clockResults: [clockOld, clockNew])
        XCTAssertEqual(snapshot.reports.map(\.id), [second.id, first.id])
        XCTAssertEqual(snapshot.clockResults.map(\.id), [clockNew.id, clockOld.id])
        XCTAssertEqual(snapshot.summaryLine, "2 reports · 0 values · 2 lab clocks")
    }

    func testNothingStoredIsEmptyAndHasNoResults() {
        let snapshot = LabsListSnapshot.make(reports: [], values: [], clockResults: [])
        XCTAssertFalse(snapshot.hasResults)
        XCTAssertEqual(snapshot.summaryLine, "0 reports · 0 values")
    }

    func testDetailGroupsValuesByBodySystemInTheCatalogOrderAndOtherTestsLast() {
        let r = report(drawn)
        let values = [value(r, .hba1c, "5.4"), value(r, .apoB, "78"), value(r, .albumin, "46"), value(r, .glucose, "90"),
                      LabValue(reportID: r.id, subject: .other(name: "Zinc"), value: 11, source: .typed)]
        let detail = LabReportDetail.make(report: r, values: values, usedForBloodAge: false) { _ in [] }
        XCTAssertEqual(detail.groups.map(\.title), ["Cardiovascular", "Metabolic", "Liver", "Other tests"])
        XCTAssertEqual(detail.groups[1].rows.map(\.name), ["HbA1c", "Glucose"])
        XCTAssertEqual(detail.valueCount, 5)
        XCTAssertFalse(detail.usedForBloodAge)
    }

    func testHistoryKeepsOnlyEarlierAndSameUnitValuesAndNeedsTwoPoints() {
        let early = report(days(-120))
        let middle = report(days(-60))
        let current = report(drawn)
        let later = report(days(30))
        let own = value(current, .glucose, "90")
        let history: [LabHistoryEntry] = [
            LabHistoryEntry(value: value(early, .glucose, "95"), report: early),
            LabHistoryEntry(value: value(middle, .glucose, "5.1", unit: "mmol/L"), report: middle),
            LabHistoryEntry(value: own, report: current),
            LabHistoryEntry(value: value(later, .glucose, "99"), report: later)
        ]
        let detail = LabReportDetail.make(report: current, values: [own], usedForBloodAge: true) { _ in history }
        let row = detail.groups[0].rows[0]
        XCTAssertEqual(row.history.map(\.value), [95, 90])
        XCTAssertTrue(detail.usedForBloodAge)
        let alone = LabReportDetail.make(report: current, values: [own], usedForBloodAge: false) { _ in [history[2]] }
        XCTAssertTrue(alone.groups[0].rows[0].history.isEmpty)
    }

    func testRangeAndFlagAreShownAsTheLabPrintedThemAndNothingIsJudged() {
        XCTAssertEqual(LabsDisplay.rangeText(LabReferenceRange(low: dec("3.5"), high: dec("5.2")), locale: Locale(identifier: "en_US")), "3.5 to 5.2")
        XCTAssertEqual(LabsDisplay.rangeText(LabReferenceRange(low: dec("3.5"), high: dec("5.2")), locale: Locale(identifier: "de_DE")), "3,5 to 5,2")
        XCTAssertEqual(LabsDisplay.rangeText(LabReferenceRange(low: 30), locale: Locale(identifier: "en_US")), "from 30")
        XCTAssertEqual(LabsDisplay.rangeText(LabReferenceRange(high: 5), locale: Locale(identifier: "en_US")), "up to 5")
        XCTAssertEqual(LabsDisplay.rangeText(LabReferenceRange(text: "<5.0")), "<5.0")
        XCTAssertNil(LabsDisplay.rangeText(.none))
        let r = report(drawn)
        var printed = value(r, .hba1c, "5")
        printed.printedValue = "5.0"
        XCTAssertEqual(LabsDisplay.valueText(printed, locale: Locale(identifier: "de_DE")), "5,0")
        let words = ["normal", "abnormal", "high", "low", "optimal", "healthy"]
        let copy = [LabsDisplay.notAMedicalDevice, LabsDisplay.reportHeader(r), LabsDisplay.labName(r)].joined(separator: " ").lowercased()
        for word in words { XCTAssertFalse(copy.contains(word), word) }
        XCTAssertEqual(LabsDisplay.reportHeader(r), "Lab report · \(LabsDisplay.day(drawn, timeZoneIdentifier: berlin)) · fasting")
    }

    // MARK: Store

    func testTheStoreBuildsTheListAndTheDetailFromWhatIsSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabsListModelTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("labs.sqlite"), applicationVersion: "labs-list-tests")
        defer { try? database.databasePool.close() }
        let store = LabStore(database: database)
        let old = report(days(-90))
        let recent = report(drawn)
        try store.saveReport(old, values: [value(old, .glucose, "95"), value(old, .albumin, "46")])
        try store.saveReport(recent, values: [value(recent, .glucose, "90", review: true)])
        try store.saveClockResult(LabClockResult(kind: .dunedinPACE, value: dec("0.92"), labName: "Lab", collectedAt: drawn,
                                                 timeZoneIdentifier: berlin, createdAt: drawn))

        let list = try store.listSnapshot()
        XCTAssertEqual(list.reports.map(\.id), [recent.id, old.id])
        XCTAssertEqual(list.reports.map(\.valueCount), [1, 2])
        XCTAssertEqual(list.needsLookTotal, 1)
        XCTAssertEqual(list.clockResults.count, 1)

        let detail = try XCTUnwrap(try store.detail(reportID: recent.id, birthYear: 1988))
        XCTAssertEqual(detail.groups.map(\.title), ["Metabolic"])
        XCTAssertEqual(detail.groups[0].rows[0].history.map(\.value), [95, 90])
        XCTAssertFalse(detail.usedForBloodAge)
        XCTAssertNil(try store.detail(reportID: UUID(), birthYear: nil))
    }

    func testBloodAgeNamesTheNewestReportWithAllNineInputsThatCalculates() {
        let old = report(days(-90))
        let recent = report(drawn)
        let partial = report(days(30))
        func nine(_ report: LabReport) -> [LabValue] {
            [value(report, .albumin, "46", unit: "g/L"), value(report, .creatinine, "84", unit: "µmol/L"),
             value(report, .glucose, "4.9", unit: "mmol/L"), value(report, .crp, "0.06", unit: "mg/dL"),
             value(report, .lymphocytePercent, "31"), value(report, .meanCellVolume, "90"),
             value(report, .redCellDistributionWidth, "12.6"), value(report, .alkalinePhosphatase, "60"),
             value(report, .whiteBloodCellCount, "5.5")]
        }
        let values = nine(old) + nine(recent) + [value(partial, .albumin, "45", unit: "g/L")]
        let fed = LabBloodAgeSource.reportID(reports: [old, recent, partial], values: values, birthYear: 1988)
        XCTAssertEqual(fed, recent.id)
        XCTAssertNil(LabBloodAgeSource.reportID(reports: [old, recent, partial], values: values, birthYear: nil))
        XCTAssertNil(LabBloodAgeSource.reportID(reports: [partial], values: [value(partial, .albumin, "45")], birthYear: 1988))
    }

    // MARK: Marker page

    func testTheMarkerPageDrawsOnlyTheOpenedUnitWithTheLabsRangeAndFlag() {
        let first = report(days(-200)), second = report(days(-100)), third = report(drawn)
        let a = LabValue(reportID: first.id, subject: .marker(.apoB), value: dec("120"), unit: "mg/dL",
                         referenceRange: LabReferenceRange(text: "<90"), flagText: "H", source: .typed)
        let b = LabValue(reportID: second.id, subject: .marker(.apoB), value: dec("1.0"), printedValue: "1.0", unit: "g/L", source: .typed)
        let c = LabValue(reportID: third.id, subject: .marker(.apoB), value: dec("200"), comparator: .greaterThan, unit: "mg/dL",
                         referenceRange: LabReferenceRange(low: dec("40"), high: dec("90")), source: .typed)
        let entries = [LabHistoryEntry(value: a, report: first), LabHistoryEntry(value: b, report: second),
                       LabHistoryEntry(value: c, report: third)]
        let detail = LabReportDetail.make(report: third, values: [c], usedForBloodAge: false) { _ in entries }
        let row = detail.rows[0]
        XCTAssertEqual(row.entries.count, 3)

        let history = LabMarkerHistory.make(row: row, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(history.points.map(\.value), [120, 200])
        XCTAssertEqual(history.otherUnitCount, 1)
        XCTAssertEqual(history.points[0].high, 90, "a range printed as <90 bounds the band from above")
        XCTAssertNil(history.points[0].low)
        XCTAssertEqual(history.points[0].flag, "H")
        XCTAssertEqual(history.points[1].low, 40)
        XCTAssertEqual(history.points[1].printed, ">200")
        XCTAssertTrue(history.points[1].isLimit && history.points[1].isOpened)
        XCTAssertEqual(history.entries.map(\.value.id), [c.id, b.id, a.id], "the list runs newest first")
        XCTAssertTrue(history.spokenSummary.contains("2 values"), history.spokenSummary)
        XCTAssertTrue(history.spokenSummary.contains("1 in another unit"), history.spokenSummary)
    }

    /// ICP R2-LAB-7, 8, 9: the marker page says who set the range, where an exact value sits in it, and that one draw
    /// has no trend yet. None of it is a judgement of Loopr's own.
    func testTheMarkerPageSaysWhoSetTheRangeWhereTheValueSitsAndThatOneDrawHasNoTrend() {
        let only = report(drawn)
        let glucose = LabValue(reportID: only.id, subject: .marker(.glucose), value: dec("92"), unit: "mg/dL",
                               referenceRange: LabReferenceRange(low: dec("70"), high: dec("99")), source: .typed)
        XCTAssertEqual(LabsDisplay.rangePosition(glucose), "Inside the lab's range")
        var high = glucose
        high.value = dec("120")
        XCTAssertEqual(LabsDisplay.rangePosition(high), "Outside the lab's range")
        var limit = glucose
        limit.comparator = .lessThan
        XCTAssertNil(LabsDisplay.rangePosition(limit), "a limit is not placed in the range")
        var oneEnd = glucose
        oneEnd.referenceRange = LabReferenceRange(high: dec("99"))
        XCTAssertNil(LabsDisplay.rangePosition(oneEnd))
        XCTAssertTrue(LabsDisplay.rangeSourceLine(hasRange: true).contains("Your lab printed this range"))
        XCTAssertTrue(LabsDisplay.rangeSourceLine(hasRange: false).contains("does not set ranges"))

        let detail = LabReportDetail.make(report: only, values: [glucose], usedForBloodAge: false) { _ in
            [LabHistoryEntry(value: glucose, report: only)]
        }
        let history = LabMarkerHistory.make(row: detail.rows[0], locale: Locale(identifier: "en_US"))
        XCTAssertEqual(history.points.count, 1)
        XCTAssertTrue(history.trendLine.hasPrefix("First draw, on "), history.trendLine)
        XCTAssertTrue(history.trendLine.hasSuffix("A second draw shows how it moves."), history.trendLine)
        let copy = [LabsDisplay.rangePosition(glucose), LabsDisplay.rangeSourceLine(hasRange: true), history.trendLine]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        for word in ["normal", "healthy", "optimal", "good", "bad"] { XCTAssertFalse(copy.contains(word), word) }
        XCTAssertEqual(MethodCatalog.entry(.labRanges).group, .labs)
    }

    func testALimitShowsWithItsSignAndIsSpokenInWords() {
        let r = report(drawn)
        let crp = LabValue(reportID: r.id, subject: .marker(.crp), value: dec("0.3"), comparator: .lessThan, unit: "mg/L", source: .typed)
        XCTAssertEqual(LabsDisplay.valueText(crp, locale: Locale(identifier: "de_DE")), "<0,3")
        XCTAssertEqual(LabsDisplay.valueWithUnit(crp, locale: Locale(identifier: "en_US")), "<0.3 mg/L")
        XCTAssertEqual(LabsDisplay.spokenValue(crp, locale: Locale(identifier: "en_US")), "below 0.3")
        XCTAssertEqual(LabsDisplay.flagText(value(r, .crp, "1")), nil)
    }

    /// ICP R3-LAB-2, R3-UPG-2: "4,5" typed under a German region showed "4.5" in the hero and "4,5" in the rows, list
    /// and edit sheet. Every lab screen now writes the value in the app's number locale, and typing takes both marks.
    func testATypedCommaValueShowsInTheAppsNumberLocaleEverywhere() throws {
        let r = report(drawn)
        let typed = try XCTUnwrap(LabEntryNumber.parseResult("4,5"))
        XCTAssertEqual(typed.value, dec("4.5"))
        XCTAssertEqual(try XCTUnwrap(LabEntryNumber.parseResult("4.5")).value, dec("4.5"))
        let limit = try XCTUnwrap(LabEntryNumber.parseResult("<0,3"))
        XCTAssertEqual(limit.comparator, .lessThan)
        let albumin = LabValue(reportID: r.id, subject: .marker(.albumin), value: typed.value, printedValue: typed.printed,
                               unit: "g/dL", referenceRange: LabReferenceRange(low: dec("3.5"), high: dec("5.2")), source: .typed)
        let crp = LabValue(reportID: r.id, subject: .marker(.crp), value: limit.value, printedValue: limit.printed,
                           comparator: limit.comparator, unit: "mg/L", source: .typed)
        XCTAssertEqual(LabsDisplay.valueWithUnit(albumin), "4.5 g/dL")
        XCTAssertEqual(LabsDisplay.valueText(crp), "<0.3")
        XCTAssertEqual(LabsDisplay.spokenValue(crp), "below 0.3")
        XCTAssertEqual(LabsDisplay.rangeText(albumin.referenceRange), "3.5 to 5.2")
        XCTAssertEqual(LabValueDraft(editing: albumin).numberText, "4.5")
        XCTAssertEqual(LabValueDraft(editing: crp).numberText, "<0.3")
        let detail = LabReportDetail.make(report: r, values: [crp], usedForBloodAge: false) { _ in [LabHistoryEntry(value: crp, report: r)] }
        XCTAssertEqual(LabMarkerHistory.make(row: detail.rows[0]).points.map(\.printed), ["<0.3"])
    }

    /// ICP R3-LAB-7: two exact draws get one sentence for the change; a limit has no exact change.
    func testTwoExactDrawsSayHowTheValueMovedAndALimitDoesNot() {
        let first = report(days(-60)), second = report(drawn)
        let a = LabValue(reportID: first.id, subject: .marker(.glucose), value: dec("108"), unit: "mg/dL", source: .typed)
        let b = LabValue(reportID: second.id, subject: .marker(.glucose), value: dec("95"), unit: "mg/dL", source: .typed)
        let entries = [LabHistoryEntry(value: a, report: first), LabHistoryEntry(value: b, report: second)]
        let detail = LabReportDetail.make(report: second, values: [b], usedForBloodAge: false) { _ in entries }
        let history = LabMarkerHistory.make(row: detail.rows[0])
        let firstDay = LabsDisplay.day(first.collectedAt, timeZoneIdentifier: berlin)
        let secondDay = LabsDisplay.day(second.collectedAt, timeZoneIdentifier: berlin)
        XCTAssertEqual(history.changeLine, "Down 13 mg/dL from \(firstDay) to \(secondDay).")
        XCTAssertTrue(history.spokenSummary.hasSuffix("Down 13 mg/dL from \(firstDay) to \(secondDay)."), history.spokenSummary)

        let c = LabValue(reportID: second.id, subject: .marker(.crp), value: dec("0.3"), comparator: .lessThan, unit: "mg/L", source: .typed)
        let d = LabValue(reportID: first.id, subject: .marker(.crp), value: dec("1.2"), unit: "mg/L", source: .typed)
        let limited = LabReportDetail.make(report: second, values: [c], usedForBloodAge: false) { _ in
            [LabHistoryEntry(value: d, report: first), LabHistoryEntry(value: c, report: second)]
        }
        XCTAssertNil(LabMarkerHistory.make(row: limited.rows[0]).changeLine)
    }

    // MARK: What a save changed

    private func nine(_ report: LabReport) -> [LabValue] {
        [value(report, .albumin, "46", unit: "g/L"), value(report, .creatinine, "84", unit: "µmol/L"),
         value(report, .glucose, "4.9", unit: "mmol/L"), value(report, .crp, "0.06", unit: "mg/dL"),
         value(report, .lymphocytePercent, "31"), value(report, .meanCellVolume, "90"),
         value(report, .redCellDistributionWidth, "12.6"), value(report, .alkalinePhosphatase, "60"),
         value(report, .whiteBloodCellCount, "5.5")]
    }

    func testASaveWithAllNineSaysTheBloodAgeOfThatDraw() throws {
        let r = report(drawn)
        let outcome = LabSaveOutcome.make(reportID: r.id, reports: [r], values: nine(r), birthYear: 1988)
        guard case .calculated(let reading) = outcome.bloodAge else { return XCTFail("\(outcome.bloodAge)") }
        XCTAssertEqual(reading.report.id, r.id)
        let line = try XCTUnwrap(outcome.bloodAgeLine)
        XCTAssertTrue(line.hasPrefix("Blood age ") && line.hasSuffix("draw."), line)
        XCTAssertEqual(outcome.firstValues.count, 9)
    }

    func testASaveMissingSomeOfTheNineNamesWhatIsLeftWithoutBlamingTheLab() throws {
        let r = report(drawn)
        let chemistry = Array(nine(r).prefix(4)) + [value(r, .alkalinePhosphatase, "60")]
        let outcome = LabSaveOutcome.make(reportID: r.id, reports: [r], values: chemistry, birthYear: 1988)
        XCTAssertEqual(outcome.bloodAge, .needs([.lymphocytePercent, .meanCellVolume, .redCellDistributionWidth, .whiteBloodCellCount]))
        let line = try XCTUnwrap(outcome.bloodAgeLine)
        XCTAssertTrue(line.hasPrefix("Blood age needs 4 more values from this draw: "), line)
        XCTAssertFalse(line.contains("has no"), line)
    }

    func testASaveWithoutAnyOfTheNineSaysNothingAboutBloodAgeAndNamesNewTests() throws {
        let old = report(days(-100)), r = report(drawn)
        let values = [value(old, .apoB, "100"), value(r, .apoB, "90"), value(r, .ferritin, "120")]
        let outcome = LabSaveOutcome.make(reportID: r.id, reports: [old, r], values: values, birthYear: 1988)
        XCTAssertEqual(outcome.bloodAge, .notInvolved)
        XCTAssertNil(outcome.bloodAgeLine)
        XCTAssertEqual(outcome.firstValues, [.marker(.ferritin)])
        XCTAssertEqual(outcome.firstValuesLine, "New in your blood tests: Ferritin.")
    }

    func testANoteNamesWhatAReportStillNeedsAndALimitSaysWhy() {
        let r = report(drawn)
        let partial = Array(nine(r).prefix(7))
        let note = LabStore.bloodAgeNote(report: r, values: partial, birthYear: 1988)
        XCTAssertEqual(note, "Blood age needs alkaline phosphatase and white blood cell count from this draw too. If they are on another page of this report, scan that page or type them in.")
        var limited = nine(r)
        limited[3].comparator = .lessThan
        let limitNote = LabStore.bloodAgeNote(report: r, values: limited, birthYear: 1988)
        XCTAssertTrue(limitNote?.contains("printed as a limit") == true, limitNote ?? "")
        XCTAssertNil(LabStore.bloodAgeNote(report: r, values: [value(r, .apoB, "90")], birthYear: 1988))
    }
}
