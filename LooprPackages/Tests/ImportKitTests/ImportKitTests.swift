import Foundation
import Compression
import ImportKit
import StorageKit
import DomainKit
import WorkoutKit
import JournalKit
import XCTest

final class ImportKitTests: XCTestCase {
    func testResultSummaryGroupsCountsAndCombinesSkippedRows() {
        var result = WHOOPImportResult()
        result.days = 412; result.sleeps = 398; result.workouts = 87
        result.journalAnswers = 1204; result.unchanged = 12; result.missingDate = 3
        let grouped = 1204.formatted(.number.grouping(.automatic))
        XCTAssertEqual(result.summary, "Added 412 days, 398 sleeps, 87 workouts and \(grouped) journal answers. Skipped 12 rows already imported and 3 rows with no date.")
        result.updatedRows = 1; result.invalidRows = 1
        XCTAssertTrue(result.summary.contains("Updated 1 row."))
        XCTAssertTrue(result.summary.contains("1 row with invalid fields"))
    }

    private var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []; super.tearDown()
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("account-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); roots.append(url); return url
    }
    private func csv(_ text: String, name: String = "physiological_cycles.csv", in directory: URL? = nil) throws -> URL {
        let url = try (directory ?? root()).appendingPathComponent(name)
        try Data(text.utf8).write(to: url); return url
    }
    private func store() throws -> (StorageDatabase, WHOOPImportStore) {
        let db = try StorageDatabase(url: root().appendingPathComponent("history.sqlite"), applicationVersion: "test")
        return (db, try WHOOPImportStore(database: db))
    }
    private let cycle = """
    Cycle start time,Wake onset,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Day Strain,Asleep duration (min),Sleep onset,Deep (SWS) duration (min),Sleep need (min)
    2021-04-02 22:15:00,2021-04-03 06:30:00,UTC+08:00,82,51,,12.4,440,2021-04-02 22:30:00,94,475
    """
    func testRealHeadersBlankCellsAndWakeDay() throws {
        var rows: [WHOOPExportRow] = []
        let summary = try WHOOPExportParser.parse(url: csv(cycle)) { rows.append($0) }
        XCTAssertEqual(summary.rows, 1); XCTAssertEqual(rows.first?.day, "2021-04-03")
        XCTAssertEqual(rows.first?.number("Resting heart rate"), 51)
        XCTAssertNil(rows.first?.number("Heart rate variability"))
        XCTAssertEqual(rows.first?.end?.timeIntervalSince1970, 1_617_402_600)
    }
    func testHeaderCaseUnitsBOMAndCRLF() throws {
        let text = "\u{FEFF}CYCLE START TIME,cycle TIMEZONE,recovery SCORE (%)\r\n2022-02-04 08:00:00,UTC-05:30,69\r\n"
        var rows: [WHOOPExportRow] = []
        try WHOOPExportParser.parse(url: csv(text)) { rows.append($0) }
        XCTAssertEqual(rows.first?.number("Recovery score"), 69)
        XCTAssertEqual(rows.first?.start.timeIntervalSince1970, 1_643_981_400)
    }
    func testBOMBeforeQuotedHeaderIsConsumedBeforeCSVQuoting() throws {
        var rows: [WHOOPExportRow] = []
        let text = "\u{FEFF}\"Cycle start time\",\"Cycle timezone\",\"Recovery score %\"\n2021-04-03 08:00:00,UTC,82"
        try WHOOPExportParser.parse(url: csv(text)) { rows.append($0) }
        XCTAssertEqual(rows.first?.number("Recovery score"), 82)
    }
    func testTimezoneCrossesUTCDateAndExplicitTimestampOffset() throws {
        let text = "Cycle start time,Cycle timezone\n2024-03-02T00:15:00+08:00,UTC+08:00\n2024-03-02T23:30:00-07:00,UTC-07:00"
        var rows: [WHOOPExportRow] = []
        try WHOOPExportParser.parse(url: csv(text)) { rows.append($0) }
        XCTAssertEqual(rows.map(\.day), ["2024-03-02", "2024-03-02"])
        XCTAssertEqual(rows[1].start.timeIntervalSince(rows[0].start), 137_700)
        XCTAssertNil(WHOOPExportParser.timeZone("UTC+14:30"))
        XCTAssertNotNil(WHOOPExportParser.timeZone("Australia/Perth"))
    }
    func testZonelessMissingTimezoneAndInvalidDatesStayMissing() throws {
        let text = "Cycle start time,Recovery score\n2023-09-02 08:00:00,91\n,70\n2023-02-31T08:00:00Z,72"
        var rows: [WHOOPExportRow] = []
        let result = try WHOOPExportParser.parse(url: csv(text)) { rows.append($0) }
        XCTAssertEqual(result.missingDate, 3); XCTAssertTrue(rows.isEmpty)
    }
    func testDuplicateNormalizedHeadersReportDuplicateColumns() throws {
        XCTAssertThrowsError(try WHOOPExportParser.parse(url: csv("Cycle start time,Cycle timezone,Recovery score %,Recovery score (%)")) { _ in }) { error in
            XCTAssertEqual(error.localizedDescription, "The CSV has duplicate column names.")
        }
    }
    func testDateOnlyValuesDoNotInventSessionTimes() throws {
        var rows: [WHOOPExportRow] = []
        let file = try csv("Workout start time,Workout end time,Cycle timezone\n2021-04-03,2021-04-04,UTC", name: "workouts.csv")
        let result = try WHOOPExportParser.parse(url: file) { rows.append($0) }
        XCTAssertEqual(result.missingDate, 1); XCTAssertTrue(rows.isEmpty)
        let cycleFile = try csv("Cycle start time,Cycle timezone\n2021-04-03,UTC")
        XCTAssertEqual(try WHOOPExportParser.parse(url: cycleFile) { _ in }.missingDate, 1)
    }
    func testInvalidTimezoneReportsProblem() throws {
        XCTAssertThrowsError(try WHOOPExportParser.parse(url: csv("Cycle start time,Cycle timezone\n2023-09-02 08:00:00,UTC+29:00")) { _ in })
    }
    func testQuotedMultilineUTF8SpansReadBuffer() throws {
        let question = String(repeating: "a", count: 65_530) + ",\nDid you say \"yes\"? café"
        let escaped = question.replacingOccurrences(of: "\"", with: "\"\"")
        let text = "Cycle start time,Cycle timezone,Question text,Answered yes,Notes\n2023-09-02 08:00:00,UTC,\"\(escaped)\",true,\"a,b\""
        var rows: [WHOOPExportRow] = []
        try WHOOPExportParser.parse(url: csv(text, name: "journal_entries.csv")) { rows.append($0) }
        XCTAssertEqual(rows.first?.text("Question text"), question); XCTAssertEqual(rows.first?.text("Notes"), "a,b")
    }
    func testBadQuotingAndInvalidUTF8Fail() throws {
        XCTAssertThrowsError(try WHOOPExportParser.parse(url: csv("Cycle start time,Cycle timezone\n\"2023-01-01,UTC")) { _ in })
        let file = try csv("Cycle start time,Cycle timezone\n")
        var data = try Data(contentsOf: file); data.append(contentsOf: [0xff, 44, 85, 84, 67]); try data.write(to: file)
        XCTAssertThrowsError(try WHOOPExportParser.parse(url: file) { _ in })
    }
    func testIdempotencyTypedModelsAndMinuteUnits() throws {
        let (db, store) = try store(); let file = try csv(cycle)
        let first = try store.apply(csvs: [file]); let second = try store.apply(csvs: [file])
        XCTAssertEqual(first.days, 1); XCTAssertEqual(second.days, 0); XCTAssertEqual(second.unchanged, 1)
        let day = try XCTUnwrap(store.day("2021-04-03"))
        XCTAssertEqual(day.today.metric(.recovery)?.numericValue, 82)
        XCTAssertNil(day.today.metric(.hrv)?.numericValue)
        XCTAssertEqual(day.sleep?.mainSleep?.durationMinutes, 440)
        XCTAssertEqual(day.sleep?.mainSleep?.isPartial, false)
        let trend = try XCTUnwrap(store.sleepTrend(endingOn: "2021-04-03").first)
        XCTAssertEqual(try XCTUnwrap(trend.value), 440.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(trend.unit, "h")
        XCTAssertTrue(day.sleep?.hypnogram.isEmpty == true)
        XCTAssertEqual(day.sleep?.metric("deep")?.numericValue, 94)
        XCTAssertEqual(try db.preferredMetricSeries(metricKey: "sleep_duration", from: "2021-04-03", through: "2021-04-03").first?.value, 440)
        XCTAssertEqual(try db.readInteger(sql: "SELECT COUNT(*) FROM whoop_export_row"), 1)
    }
    func testTotalEnergyDoesNotBecomeActiveEnergy() throws {
        let (db, store) = try store()
        let file = try csv("Cycle start time,Cycle timezone,Energy burned (cal)\n2021-04-03 08:00:00,UTC,2450")
        _ = try store.apply(csvs: [file])
        XCTAssertEqual(try store.day("2021-04-03")?.totalEnergyKcal, 2450)
        XCTAssertNil(try store.day("2021-04-03")?.today.metric(.calories))
        XCTAssertTrue(try db.metricSeries(metricKey: "active_energy", from: "2021-04-03", through: "2021-04-03").isEmpty)
    }

    func testPreviouslySavedExportNightsAreCompletedWithoutReimporting() throws {
        let (db, store) = try store()
        _ = try store.apply(csvs: [csv(cycle)])
        let model = try XCTUnwrap(store.day("2021-04-03"))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        var sleep = try XCTUnwrap(legacy["sleep"] as? [String: Any])
        var main = try XCTUnwrap(sleep["mainSleep"] as? [String: Any])
        main["isPartial"] = true
        sleep["mainSleep"] = main
        legacy["sleep"] = sleep
        let payload = try JSONSerialization.data(withJSONObject: legacy)
        try db.write { connection in
            try connection.execute(sql: "UPDATE whoop_export_day SET payload = ? WHERE local_day = '2021-04-03'", arguments: [payload])
        }
        let reopened = try WHOOPImportStore(database: db)
        let corrected = try XCTUnwrap(reopened.day("2021-04-03"))
        XCTAssertEqual(corrected.sleep?.mainSleep?.isPartial, false)
        XCTAssertEqual(corrected.sleep?.mainSleep?.durationMinutes, 440)
        XCTAssertEqual(corrected.today.metric(.recovery)?.numericValue, model.today.metric(.recovery)?.numericValue)
        XCTAssertEqual(try db.preferredMetricSeries(metricKey: "sleep_duration", from: "2021-04-03", through: "2021-04-03").first?.value, 440)
    }
    func testBandWinsBeforeAndAfterImport() throws {
        let (db, store) = try store(); let file = try csv(cycle)
        try db.upsertMetricSeries([.init(localDay: "2021-04-03", metricKey: "recovery", source: .band, value: 74)], updatedAt: 1)
        _ = try store.apply(csvs: [file])
        XCTAssertEqual(try db.preferredMetricSeries(metricKey: "recovery", from: "2021-04-03", through: "2021-04-03").first?.source, .band)
        try db.upsertMetricSeries([.init(localDay: "2021-04-03", metricKey: "recovery", source: .band, value: 77)], updatedAt: 2)
        _ = try store.apply(csvs: [file])
        XCTAssertEqual(try db.preferredMetricSeries(metricKey: "recovery", from: "2021-04-03", through: "2021-04-03").first?.value, 77)
        XCTAssertEqual(try db.metricSeries(metricKey: "recovery", from: "2021-04-03", through: "2021-04-03").count, 2)
    }
    func testChangedImportClearsAbsentMetricAndMalformedSelectionRollsBack() throws {
        let (db, store) = try store(); let file = try csv(cycle)
        _ = try store.apply(csvs: [file])
        try Data(cycle.replacingOccurrences(of: ",82,51,", with: ",,51,").utf8).write(to: file)
        _ = try store.apply(csvs: [file])
        XCTAssertNil(try store.day("2021-04-03")?.today.metric(.recovery)?.numericValue)
        XCTAssertTrue(try db.metricSeries(metricKey: "recovery", from: "2021-04-03", through: "2021-04-03").isEmpty)
        let new = try csv(cycle.replacingOccurrences(of: "2021-04-0", with: "2022-04-0"))
        let bad = try csv("not,a,valid,header", name: "sleeps.csv")
        XCTAssertThrowsError(try store.apply(csvs: [new, bad]))
        XCTAssertNil(try store.day("2022-04-03"))
    }
    func testCorrectedWakeDateMovesCycleWithoutLeavingDuplicateHistory() throws {
        let (db, store) = try store(); let file = try csv(cycle)
        _ = try store.apply(csvs: [file])
        try Data(cycle.replacingOccurrences(of: "2021-04-03 06:30:00", with: "2021-04-04 06:30:00").utf8).write(to: file)
        _ = try store.apply(csvs: [file])
        XCTAssertNil(try store.day("2021-04-03"))
        XCTAssertNotNil(try store.day("2021-04-04"))
        XCTAssertEqual(try db.readInteger(sql: "SELECT COUNT(*) FROM whoop_export_row"), 1)
        XCTAssertTrue(try db.metricSeries(metricKey: "recovery", from: "2021-04-03", through: "2021-04-03").isEmpty)
    }
    func testSleepsAndNapsUseWakeTimezoneAndNoInventedMetrics() throws {
        let (_, store) = try store()
        let file = try csv("""
        Cycle start time,Sleep onset,Wake onset,Cycle timezone,Nap,Asleep duration (min),REM duration (min)
        2021-04-02 22:15:00,2021-04-02 22:30:00,2021-04-03 06:30:00,UTC+08:00,false,440,
        2021-04-03 13:00:00,2021-04-03 13:00:00,2021-04-03 13:40:00,UTC+08:00,true,30,4
        """, name: "sleeps.csv")
        let result = try store.apply(csvs: [file]); let day = try XCTUnwrap(store.day("2021-04-03"))
        XCTAssertEqual(result.sleeps, 2); XCTAssertEqual(result.days, 1)
        XCTAssertEqual(day.sleep?.naps.count, 1); XCTAssertNil(day.sleep?.metric("rem")?.numericValue)
        XCTAssertEqual(day.sleep?.naps.first?.isPartial, false)
        XCTAssertNil(day.today.metric(.recovery)?.numericValue)
        XCTAssertEqual(try store.sleepTrend(endingOn: "2021-04-03").count, 1)
    }
    func testWorkoutsAreIdempotentAndNativeSessionWins() throws {
        let (_, store) = try store()
        let file = try csv("""
        Workout start time,Workout end time,Cycle timezone,Activity name,Activity Strain
        2021-04-03 10:00:00,2021-04-03 10:35:00,UTC+08:00,Running,7.5
        """, name: "workouts.csv")
        XCTAssertEqual(try store.apply(csvs: [file]).workouts, 1)
        XCTAssertEqual(try store.apply(csvs: [file]).workouts, 0)
        let imported = try XCTUnwrap(store.workouts().first)
        XCTAssertEqual(imported.source, .imported); XCTAssertEqual(imported.activity, .run)
        XCTAssertEqual(imported.finalizationStage, .activeStateCleared)
        XCTAssertTrue(imported.samples.isEmpty)
        XCTAssertEqual(imported.importedSummary?.strain, 7.5)
        XCTAssertNil(imported.importedSummary?.averageHeartRate)
        var native = imported
        native.source = .live
        let resolved = WHOOPImportResolution.workouts(native: [native], imported: [imported])
        XCTAssertEqual(resolved, [native])
        let differentID = WorkoutRecord(id: UUID(), identity: .init(canonicalKey: "band:abc"), activity: .run,
            source: .detected, state: .completed, createdAt: imported.createdAt,
            startedAt: imported.startedAt?.addingTimeInterval(20), endedAt: imported.endedAt?.addingTimeInterval(20))
        XCTAssertEqual(WHOOPImportResolution.workouts(native: [differentID], imported: [imported]), [differentID])
    }
    func testJournalAnswersMatchCycleWakeDayAndNativeWins() throws {
        let (_, store) = try store()
        let journal = try csv("""
        Cycle start time,Cycle timezone,Question text,Answered yes,Notes
        2021-04-02 22:15:00,UTC+08:00,Alcohol,false,
        2021-04-02 22:15:00,UTC+08:00,Caffeine,true,
        2021-04-02 22:15:00,UTC+08:00,Unknown question,true,
        """, name: "journal_entries.csv")
        _ = try store.apply(csvs: [journal]); _ = try store.apply(csvs: [csv(cycle)])
        let entries = try store.journals(); XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.day, "2021-04-03"); XCTAssertEqual(entries.first?.behaviors, ["Caffeine"])
        XCTAssertTrue(entries.first?.note?.contains("Alcohol: No") == true)
        let native = JournalEntry(day: "2021-04-03", behaviors: ["Meditation"])
        XCTAssertEqual(WHOOPImportResolution.journals(native: [native], imported: entries), [native])
        _ = try store.apply(csvs: [journal]); XCTAssertEqual(try store.journals().count, 1)
    }
    func testDeletedImportedModelsStayDeletedUntilTheirSourceIsSelectedAgain() throws {
        let (_, store) = try store()
        let workout = try csv("Workout start time,Workout end time,Cycle timezone,Activity name\n2021-04-03 10:00:00,2021-04-03 10:30:00,UTC,Running", name: "workouts.csv")
        let journal = try csv("Cycle start time,Cycle timezone,Question text,Answered yes\n2021-04-02 22:15:00,UTC+08:00,Alcohol,true", name: "journal_entries.csv")
        let cycleFile = try csv(cycle)
        _ = try store.apply(csvs: [workout, journal, cycleFile])
        try store.removeWorkout(id: XCTUnwrap(store.workouts().first).id)
        try store.removeJournal(id: XCTUnwrap(store.journals().first).id)
        _ = try store.apply(csvs: [cycleFile])
        XCTAssertTrue(try store.workouts().isEmpty); XCTAssertTrue(try store.journals().isEmpty)
        _ = try store.apply(csvs: [workout, journal])
        XCTAssertEqual(try store.workouts().count, 1); XCTAssertEqual(try store.journals().count, 1)
    }
    func testYearsOfHistoryUseBoundedSleepQueryAndSurviveReopen() throws {
        let (db, store) = try store()
        var text = "Cycle start time,Cycle timezone,Wake onset,Asleep duration (min),Sleep onset\n"
        let zone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_577_836_800)
        for index in 0..<2_000 {
            let day = WHOOPExportParser.dayLabel(start.addingTimeInterval(Double(index) * 86_400), zone: zone)
            text += "\(day) 01:00:00,UTC,\(day) 08:00:00,390,\(day) 01:00:00\n"
        }
        XCTAssertEqual(try store.apply(csvs: [csv(text)]).days, 2_000)
        let reopenedDatabase = try StorageDatabase(path: db.path, applicationVersion: "test")
        let reopened = try WHOOPImportStore(database: reopenedDatabase)
        let end = WHOOPExportParser.dayLabel(start.addingTimeInterval(1_999 * 86_400), zone: zone)
        XCTAssertEqual(try reopened.sleepTrend(endingOn: end).count, 31)
        XCTAssertEqual(try db.metricSeriesDays(source: .whoopExport, from: "2020-01-01", through: end).count, 2_000)
    }
    func testStoredAndDeflateZIPWithNestedPathsAndDescriptors() throws {
        for method in [0, 8] {
            for descriptor in [false, true] {
                let directory = try root(); let archive = directory.appendingPathComponent("export.zip")
                try zip(name: "export/physiological_cycles.csv", text: cycle, method: method, descriptor: descriptor).write(to: archive)
                let output = try WHOOPZIPReader.extractCSVs(from: archive, into: directory)
                XCTAssertEqual(output.count, 1); XCTAssertEqual(try String(contentsOf: output[0], encoding: .utf8), cycle)
            }
        }
    }
    func testZIPCRCTruncationUnsafePathsEncryptionAndOversizedEntriesFail() throws {
        let directory = try root(); let archive = directory.appendingPathComponent("export.zip")
        var badCRC = try zip(name: "physiological_cycles.csv", text: cycle); badCRC[30 + "physiological_cycles.csv".utf8.count] ^= 1
        var encrypted = try zip(name: "physiological_cycles.csv", text: cycle); encrypted[6] = 1
        let central = encrypted.count - 22 - 46 - "physiological_cycles.csv".utf8.count; encrypted[central + 8] = 1
        var oversized = try zip(name: "physiological_cycles.csv", text: cycle)
        oversized.replaceSubrange((central + 24)..<(central + 28), with: le32(300 * 1_024 * 1_024))
        var unsupported = try zip(name: "physiological_cycles.csv", text: cycle); unsupported[central + 10] = 99
        let truncated = Data(try zip(name: "physiological_cycles.csv", text: cycle).dropLast(5))
        for bytes in [badCRC, encrypted, oversized, unsupported, truncated, try zip(name: "../physiological_cycles.csv", text: cycle)] {
            try bytes.write(to: archive)
            XCTAssertThrowsError(try WHOOPZIPReader.extractCSVs(from: archive, into: directory))
        }
    }
    func testFolderAndZIPImporterUseSameDurablePath() async throws {
        let (_, store) = try store(); let directory = try root()
        _ = try csv(cycle, in: directory)
        let importer = WHOOPExportImporter(store: store)
        let folderResult = try await importer.importFiles([directory])
        XCTAssertEqual(folderResult.days, 1)
        let archive = directory.appendingPathComponent("account.zip")
        try zip(name: "physiological_cycles.csv", text: cycle, method: 8, descriptor: true).write(to: archive)
        let result = try await importer.importFiles([archive]); XCTAssertEqual(result.unchanged, 1)
    }
    // All archives are generated from the invented rows above, not upstream
    // fixture archives. This small independent encoder writes ZIP facts.
    private func le16(_ value: Int) -> Data { Data([UInt8(value & 255), UInt8((value >> 8) & 255)]) }
    private func le32(_ value: Int) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
    private func crc(_ data: Data) -> Int {
        var value: UInt32 = 0xffffffff
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1 }
        }
        return Int(value ^ 0xffffffff)
    }
    private func zip(name: String, text: String, method: Int = 0, descriptor: Bool = false) throws -> Data {
        let input = Data(text.utf8); let filename = Data(name.utf8); var compressed = input
        if method == 8 {
            var buffer = [UInt8](repeating: 0, count: input.count * 2 + 128)
            let count = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                compression_encode_buffer(&buffer, buffer.count, raw.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
            XCTAssertGreaterThan(count, 0); compressed = Data(buffer.prefix(count))
        }
        let flags = descriptor ? 8 : 0; let checksum = crc(input)
        var data = Data()
        let localParts: [Data] = [
            le32(0x04034b50), le16(20), le16(flags), le16(method), le32(0),
            le32(descriptor ? 0 : checksum), le32(descriptor ? 0 : compressed.count), le32(descriptor ? 0 : input.count),
            le16(filename.count), le16(0), filename, compressed
        ]
        for part in localParts { data.append(part) }
        if descriptor {
            for part in [le32(0x08074b50), le32(checksum), le32(compressed.count), le32(input.count)] { data.append(part) }
        }
        let central = data.count
        let centralParts: [Data] = [
            le32(0x02014b50), le16(20), le16(20), le16(flags), le16(method), le32(0),
            le32(checksum), le32(compressed.count), le32(input.count), le16(filename.count), le16(0), le16(0),
            le16(0), le16(0), le32(0), le32(0), filename
        ]
        for part in centralParts { data.append(part) }
        let size = data.count - central
        let footerParts: [Data] = [le32(0x06054b50), le16(0), le16(0), le16(1), le16(1), le32(size), le32(central), le16(0)]
        for part in footerParts { data.append(part) }
        return data
    }
}
