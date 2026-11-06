import AnalyticsKit
import DataKit
import StorageKit
import XCTest

final class LabEntryDraftTests: XCTestCase {
    private let berlin = "Europe/Berlin"
    /// 20 October 2026, 10:00 in Berlin.
    private let now = Date(timeIntervalSince1970: 1_792_483_200)

    private func dec(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    private func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    private func draft(_ values: [LabValueDraft], lab: String = "Labor Berlin", on date: Date? = nil,
                       fasting: LabTypedReportDraft.Fasting = .fasting) -> LabTypedReportDraft {
        LabTypedReportDraft(collectedOn: date ?? now, timeZoneIdentifier: berlin, labName: lab, fasting: fasting, values: values)
    }

    private func number(_ key: LabMarkerKey, _ text: String, unit: String? = nil) -> LabValueDraft {
        LabValueDraft(subject: .marker(key), numberText: text, unit: unit)
    }

    func testADecimalCommaIsReadAsADecimalPointAndTheTypedDigitsAreKept() throws {
        let built = try draft([number(.hba1c, "5,40")]).build(now: now)
        let value = try XCTUnwrap(built.values.first)
        XCTAssertEqual(value.value, dec("5.4"))
        XCTAssertEqual(value.printedValue, "5.40")
        XCTAssertEqual(value.displayValue, "5.40")
        XCTAssertEqual(value.source, .typed)
        XCTAssertFalse(value.needsReview)
        XCTAssertNil(value.scanConfidence)
    }

    func testAPlainNumberKeepsNoPrintedDigitsAndTrailingZerosSurvive() throws {
        let plain = try draft([number(.apoB, "78")]).build(now: now).values[0]
        XCTAssertEqual(plain.value, dec("78"))
        XCTAssertNil(plain.printedValue)
        let zero = try draft([number(.hba1c, "5.0")]).build(now: now).values[0]
        XCTAssertEqual(zero.value, 5)
        XCTAssertEqual(zero.printedValue, "5.0")
    }

    func testSeparatorsThatCouldMeanTwoThingsAreRefused() {
        for text in ["1,234.5", "1.234,5", "5,4,3", "1 234", "5.4.3", ".5", "5.", "abc", "5e3", "--5"] {
            XCTAssertThrowsError(try draft([number(.hba1c, text)]).build(now: now), text) { error in
                XCTAssertEqual(error as? LabEntryError, .unreadableNumber("HbA1c"), text)
            }
        }
    }

    func testAResultPrintedAsALimitIsTypedWithItsSign() throws {
        let below = try draft([number(.crp, "<0,3", unit: "mg/L")]).build(now: now).values[0]
        XCTAssertEqual(below.comparator, .lessThan)
        XCTAssertEqual(below.value, dec("0.3"))
        XCTAssertEqual(below.printedText, "<0.3")
        let above = try draft([number(.apoB, "> 200")]).build(now: now).values[0]
        XCTAssertEqual(above.comparator, .greaterThan)
        XCTAssertEqual(above.value, dec("200"))
        let atMost = try draft([number(.hba1c, "≤5.0")]).build(now: now).values[0]
        XCTAssertEqual(atMost.comparator, .lessThanOrEqual)
        XCTAssertEqual(atMost.printedValue, "5.0")
        XCTAssertNil(try draft([number(.hba1c, "5.4")]).build(now: now).values[0].comparator)
        // A sign with nothing after it, or a sign that is not one of the four, is not a number.
        for text in ["<", "=5", "<<5", "< abc"] {
            XCTAssertThrowsError(try draft([number(.hba1c, text)]).build(now: now), text) { error in
                XCTAssertEqual(error as? LabEntryError, .unreadableNumber("HbA1c"), text)
            }
        }
    }

    func testTheSignPickerRewritesOnlyTheFrontOfTheNumber() throws {
        var value = number(.crp, "0,3", unit: "mg/L")
        XCTAssertNil(value.comparator)
        value.comparator = .lessThan
        XCTAssertEqual(value.numberText, "<0,3")
        value.comparator = .greaterThanOrEqual
        XCTAssertEqual(value.numberText, "≥0,3")
        value.comparator = nil
        XCTAssertEqual(value.numberText, "0,3")

        // Editing a stored limit starts from the sign and the digits as printed.
        let stored = LabValue(reportID: UUID(), subject: .marker(.crp), value: dec("0.3"), comparator: .lessThan, unit: "mg/L", source: .typed)
        let edit = LabValueDraft(editing: stored, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(edit.numberText, "<0,3")
        XCTAssertEqual(try edit.build(reportID: stored.reportID).comparator, .lessThan)
    }

    func testAMissingNumberIsNamedByMarker() {
        XCTAssertThrowsError(try draft([number(.albumin, "  ")]).build(now: now)) {
            XCTAssertEqual($0 as? LabEntryError, .missingNumber("Albumin"))
        }
    }

    func testTheUnitMustBeOneTheMarkerListsOrNone() throws {
        let picked = try draft([number(.glucose, "4,9", unit: "mmol/L")]).build(now: now).values[0]
        XCTAssertEqual(picked.unit, "mmol/L")
        let defaulted = try draft([number(.glucose, "90")]).build(now: now).values[0]
        XCTAssertEqual(defaulted.unit, "mg/dL")
        var none = number(.glucose, "90")
        none.unit = nil
        XCTAssertNil(try draft([none]).build(now: now).values[0].unit)
        XCTAssertThrowsError(try draft([number(.glucose, "90", unit: "g/L")]).build(now: now)) {
            XCTAssertEqual($0 as? LabEntryError, .unitNotListed(marker: "Glucose", unit: "g/L"))
        }
    }

    func testAnOtherTestTakesAnyUnitAndNeedsAName() throws {
        let other = LabValueDraft(subject: .other(name: "  Zinc "), numberText: "11,2", unit: "µmol/L")
        let value = try draft([other]).build(now: now).values[0]
        XCTAssertEqual(value.subject, .other(name: "Zinc"))
        XCTAssertEqual(value.unit, "µmol/L")
        // "11,2" reads as 11.2 and matches the plain number, so no printed digits are kept.
        XCTAssertEqual(value.value, Decimal(string: "11.2"))
        XCTAssertNil(value.printedValue)
        let blank = LabValueDraft(subject: .other(name: "  "), numberText: "1")
        XCTAssertThrowsError(try draft([blank]).build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .blankTestName) }
    }

    func testRangeFormsLowOnlyHighOnlyBothAndText() throws {
        var value = number(.ferritin, "88")
        value.rangeLowText = "30"
        XCTAssertEqual(try draft([value]).build(now: now).values[0].referenceRange, LabReferenceRange(low: 30))
        value.rangeLowText = ""
        value.rangeHighText = "400,5"
        XCTAssertEqual(try draft([value]).build(now: now).values[0].referenceRange, LabReferenceRange(high: dec("400.5")))
        value.rangeLowText = "30"
        XCTAssertEqual(try draft([value]).build(now: now).values[0].referenceRange,
                       LabReferenceRange(low: 30, high: dec("400.5")))
        value.rangeLowText = ""
        value.rangeHighText = ""
        value.rangeText = " <5.0 "
        XCTAssertEqual(try draft([value]).build(now: now).values[0].referenceRange, LabReferenceRange(text: "<5.0"))
        value.rangeText = ""
        XCTAssertTrue(try draft([value]).build(now: now).values[0].referenceRange.isEmpty)
    }

    func testRangeMistakesAreRefusedByName() {
        var value = number(.ferritin, "88")
        value.rangeLowText = "50"
        value.rangeHighText = "30"
        XCTAssertThrowsError(try draft([value]).build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .rangeOutOfOrder("Ferritin")) }
        value.rangeHighText = "x"
        XCTAssertThrowsError(try draft([value]).build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .unreadableRange("Ferritin")) }
        value.rangeHighText = "90"
        value.rangeText = "negativ"
        XCTAssertThrowsError(try draft([value]).build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .rangeMixed("Ferritin")) }
    }

    func testTheFlagIsStoredAsPrintedAndNeverSetByLoopr() throws {
        var flagged = number(.crp, "6,1")
        flagged.flagText = " H "
        XCTAssertEqual(try draft([flagged]).build(now: now).values[0].flagText, "H")
        XCTAssertNil(try draft([number(.crp, "0,6")]).build(now: now).values[0].flagText)
        flagged.flagText = String(repeating: "x", count: LabValueDraft.maximumFlagLength + 1)
        XCTAssertThrowsError(try draft([flagged]).build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .flagTooLong("C-reactive protein")) }
    }

    func testAReportNeedsValuesAndAPastOrPresentDayAndNoRepeatedMarker() {
        XCTAssertThrowsError(try draft([]).build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .noValues) }
        XCTAssertThrowsError(try draft([number(.albumin, "46")], on: day(2)).build(now: now)) {
            XCTAssertEqual($0 as? LabEntryError, .futureDate)
        }
        XCTAssertThrowsError(try draft([number(.albumin, "46"), number(.albumin, "47")]).build(now: now)) {
            XCTAssertEqual($0 as? LabEntryError, .duplicateMarker("Albumin"))
        }
    }

    func testTheReportIsTypedFastingIsThreeWayAndTheLabNameIsOptional() throws {
        let fasting = try draft([number(.albumin, "46")], fasting: .fasting).build(now: now).report
        XCTAssertEqual(fasting.fasting, true)
        XCTAssertEqual(fasting.source, .typed)
        XCTAssertEqual(fasting.labName, "Labor Berlin")
        XCTAssertEqual(fasting.createdAt, now)
        let notFasting = try draft([number(.albumin, "46")], lab: "  ", fasting: .notFasting).build(now: now).report
        XCTAssertEqual(notFasting.fasting, false)
        XCTAssertNil(notFasting.labName)
        let unknown = try draft([number(.albumin, "46")], fasting: .unknown).build(now: now).report
        XCTAssertNil(unknown.fasting)
    }

    func testTheCollectionDayIsTheDayPickedInTheReportsOwnZone() throws {
        let built = try draft([number(.albumin, "46")], on: day(-5)).build(now: now).report
        XCTAssertEqual(built.collectedDay, "2026-10-15")
        // Today is allowed, in the zone's own calendar.
        XCTAssertEqual(try draft([number(.albumin, "46")]).build(now: now).report.collectedDay, "2026-10-20")
    }

    func testEveryValueSharesTheReportIDAndKeepsItsOrder() throws {
        let built = try draft([number(.albumin, "46"), number(.hba1c, "5,4"), number(.glucose, "4,9", unit: "mmol/L")]).build(now: now)
        XCTAssertEqual(built.values.map(\.subject.markerKey), [.albumin, .hba1c, .glucose])
        XCTAssertTrue(built.values.allSatisfy { $0.reportID == built.report.id })
    }

    func testTheBuiltReportSavesAndReadsBackWithItsPrintedDigits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabEntryDraftTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("labs.sqlite"), applicationVersion: "lab-entry-tests")
        defer { try? database.databasePool.close() }
        let store = LabStore(database: database)
        var value = number(.hba1c, "5,0")
        value.rangeLowText = "4,0"
        value.rangeHighText = "5,6"
        value.flagText = "*"
        let built = try draft([number(.albumin, "46"), value]).build(now: now)
        try store.saveReport(built.report, values: built.values)
        XCTAssertEqual(try store.report(id: built.report.id), built.report)
        let read = try store.values(reportID: built.report.id)
        XCTAssertEqual(read, built.values)
        XCTAssertEqual(read[1].displayValue, "5.0")
        XCTAssertEqual(read[1].referenceRange, LabReferenceRange(low: 4, high: dec("5.6")))
        XCTAssertEqual(read[1].flagText, "*")
    }

    func testEditingAStoredValueKeepsItsIdentitySourceAndUnitSpelling() throws {
        let reportID = UUID()
        let scanned = LabValue(reportID: reportID, subject: .marker(.crp), assay: "hs-CRP", value: dec("0.6"), unit: "mg / L",
                               flagText: "H", source: .scan, scanConfidence: 0.4, needsReview: true)
        var edit = LabValueDraft(editing: scanned, locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(edit.numberText, "0,6")
        edit.numberText = "0,7"
        let saved = try edit.build(reportID: reportID)
        XCTAssertEqual(saved.id, scanned.id)
        XCTAssertEqual(saved.value, dec("0.7"))
        XCTAssertEqual(saved.unit, "mg / L")
        XCTAssertEqual(saved.source, .scan)
        XCTAssertEqual(saved.scanConfidence, 0.4)
        XCTAssertEqual(saved.assay, "hs-CRP")
        XCTAssertEqual(saved.flagText, "H")
        XCTAssertFalse(saved.needsReview)
    }

    // MARK: Lab clock

    func testALabClockNeedsTheLabsName() {
        let clock = LabClockDraft(valueText: "0,92", labName: "  ", collectedOn: now, timeZoneIdentifier: berlin)
        XCTAssertThrowsError(try clock.build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .blankLabName) }
    }

    func testALabClockResultIsStoredAsTheLabPrintedIt() throws {
        let dunedin = LabClockDraft(choice: .dunedinPACE, valueText: "0,92", labName: " TruDiagnostic ", collectedOn: day(-3),
                                    timeZoneIdentifier: berlin, note: " second draw ")
        let result = try dunedin.build(now: now)
        XCTAssertEqual(result.kind, .dunedinPACE)
        XCTAssertEqual(result.value, dec("0.92"))
        XCTAssertNil(result.unit)
        XCTAssertEqual(result.labName, "TruDiagnostic")
        XCTAssertEqual(result.note, "second draw")
        XCTAssertEqual(result.collectedDay, "2026-10-17")

        let grim = LabClockDraft(choice: .grimAge, valueText: "41,3", unit: "years", labName: "Lab", collectedOn: now,
                                 timeZoneIdentifier: berlin)
        let grimResult = try grim.build(now: now)
        XCTAssertEqual(grimResult.kind, .grimAge)
        XCTAssertEqual(grimResult.unit, "years")
        XCTAssertEqual(grimResult.value, dec("41.3"))
    }

    func testAnotherClockNeedsAName() throws {
        var other = LabClockDraft(choice: .other, otherName: "  ", valueText: "3", labName: "Lab", collectedOn: now, timeZoneIdentifier: berlin)
        XCTAssertThrowsError(try other.build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .blankTestName) }
        other.otherName = "Horvath"
        XCTAssertEqual(try other.build(now: now).kind, .other(name: "Horvath"))
    }

    func testALabClockRefusesAMissingNumberAndAFutureDay() {
        var clock = LabClockDraft(valueText: "", labName: "Lab", collectedOn: now, timeZoneIdentifier: berlin)
        XCTAssertThrowsError(try clock.build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .missingNumber("DunedinPACE")) }
        clock.valueText = "1,x"
        XCTAssertThrowsError(try clock.build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .unreadableNumber("DunedinPACE")) }
        clock.valueText = "1"
        clock.collectedOn = day(3)
        XCTAssertThrowsError(try clock.build(now: now)) { XCTAssertEqual($0 as? LabEntryError, .futureDate) }
    }

    /// ICP R2-LAB-5: Day drawn read 15 Nov and the report said 14 Nov. The picker showed the day in one zone and the
    /// save read it in another. The draft now keeps the day itself and the picker shows it in the report's zone, so
    /// the day saved, stored and shown is the day picked, east and west of UTC.
    func testThePickedDayIsTheSavedAndShownDayInZonesEastAndWestOfUTC() throws {
        for zone in ["Europe/Berlin", "America/Los_Angeles", "Australia/Perth", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let fifteenth = LabCalendarDay(year: 2023, month: 11, day: 15)
            // What a date picker in that zone hands back for 15 Nov: midnight, a minute after it, or late evening.
            for hour in [0, 23] {
                let picked = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: hour, minute: hour == 0 ? 1 : 59)))
                var draft = LabTypedReportDraft(collectedOn: Date(timeIntervalSince1970: 0), timeZoneIdentifier: zone,
                                                values: [LabValueDraft(subject: .marker(.glucose), numberText: "92")])
                draft.collectedOn = picked
                XCTAssertEqual(draft.collectedDay, fifteenth, "\(zone) \(hour):xx")
                // The picker reads the day back from the same zone.
                XCTAssertEqual(calendar.component(.day, from: draft.collectedOn), 15, zone)
                let later = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 11, day: 16, hour: 9)))
                let report = try draft.build(now: later).report
                XCTAssertEqual(report.collectedDay, "2023-11-15", zone)

                let root = FileManager.default.temporaryDirectory.appendingPathComponent("LabEntryDraftTests-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let store = LabStore(database: try StorageDatabase(url: root.appendingPathComponent("labs.sqlite"), applicationVersion: "lab-day-tests"))
                try store.saveReport(report, values: try draft.build(now: later, id: report.id).values)
                let stored = try XCTUnwrap(store.report(id: report.id))
                XCTAssertEqual(stored.collectedDay, "2023-11-15", zone)
                XCTAssertEqual(LabsDisplay.day(stored.collectedAt, timeZoneIdentifier: stored.timeZoneIdentifier,
                                               locale: Locale(identifier: "en_GB")), "15 Nov 2023", zone)
            }
        }
    }

    func testTodayCanBePickedAndTomorrowCannotInTheReportsZone() throws {
        let zone = "America/Los_Angeles"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        // 07:30 in Los Angeles, already the next day in UTC and Berlin.
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2023, month: 11, day: 15, hour: 7, minute: 30)))
        let values = [LabValueDraft(subject: .marker(.glucose), numberText: "92")]
        let today = LabTypedReportDraft(collectedOn: morning, timeZoneIdentifier: zone, values: values)
        XCTAssertEqual(try today.build(now: morning).report.collectedDay, "2023-11-15")
        var tomorrow = today
        tomorrow.collectedDay = LabCalendarDay(year: 2023, month: 11, day: 16)
        XCTAssertThrowsError(try tomorrow.build(now: morning)) { XCTAssertEqual($0 as? LabEntryError, .futureDate) }
    }

    func testARefusalAboutOneValueNamesThatValue() {
        XCTAssertEqual(LabEntryError.rangeOutOfOrder("Glucose").valueName, "Glucose")
        XCTAssertEqual(LabEntryError.unitNotListed(marker: "Glucose", unit: "g").valueName, "Glucose")
        XCTAssertNil(LabEntryError.noValues.valueName)
        XCTAssertNil(LabEntryError.futureDate.valueName)
    }

    func testEveryRefusalHasAPlainMessage() {
        let errors: [LabEntryError] = [.noValues, .futureDate, .blankLabName, .blankTestName, .missingNumber("A"),
            .unreadableNumber("A"), .unitNotListed(marker: "A", unit: "b"), .unreadableRange("A"), .rangeOutOfOrder("A"),
            .rangeMixed("A"), .flagTooLong("A"), .duplicateMarker("A"), .model(.printedValueMismatch), .model(.blankName)]
        for error in errors {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertFalse(error.message.contains("—"), error.message)
            XCTAssertFalse(error.message.contains("!"), error.message)
        }
    }
}
