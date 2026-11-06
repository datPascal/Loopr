import DataKit
import XCTest

final class PublishRendererTests: XCTestCase {
    /// 25 October 2026, 12:00 in UTC.
    private let exportedAt = Date(timeIntervalSince1970: 1_792_929_600)
    private let utc = TimeZone(identifier: "UTC")!

    private func series(_ key: String, _ name: String, unit: String = "bpm", group: PublishGroup = .heart,
                        source: String = "Loopr band", days: [(String, Double)]) -> PublishMetricSeries {
        PublishMetricSeries(key: key, name: name, unit: unit, group: group, source: source,
                            values: days.map { PublishDayValue(date: $0.0, value: $0.1) })
    }

    private var resting: PublishMetricSeries {
        series("resting_heart_rate", "Resting heart rate",
               days: [("2026-10-20", 55), ("2026-10-21", 54), ("2026-10-23", 52), ("2026-10-25", 53)])
    }
    private var sleep: PublishMetricSeries {
        series("sleep_duration", "Sleep duration", unit: "min", group: .sleep, source: "Apple Health",
               days: [("2026-10-22", 440), ("2026-10-24", 455)])
    }
    private var unpicked: [PublishMetricSeries] {
        [series("steps", "Steps", unit: "steps", group: .fitness, days: [("2026-10-24", 8_000)]),
         series("stress", "Stress", unit: "score", days: [("2026-10-24", 40)]),
         series("recovery", "Recovery", unit: "score", days: [("2026-10-24", 71)]),
         series("rmssd", "HRV", unit: "ms", days: [("2026-10-24", 60)]),
         series("strain", "Strain", unit: "/21", group: .fitness, days: [("2026-10-24", 12)])]
    }

    private func dashboard(_ items: [PublishMetricSeries], period: PublishPeriod = .days30, labs: Bool = false) -> PublishDashboard {
        PublishDashboard.make(series: items, period: period, exportedAt: exportedAt, timeZone: utc, includeBloodTests: labs)
    }

    private func outputs(_ dashboard: PublishDashboard) throws -> (html: String, json: String) {
        (PublishHTMLRenderer.render(dashboard), String(decoding: try PublishJSONRenderer.render(dashboard), as: UTF8.self))
    }

    // MARK: Only picked metrics

    func testOnlyPickedMetricsAppearInBothFiles() throws {
        let (html, json) = try outputs(dashboard([resting, sleep]))
        for picked in [resting, sleep] {
            XCTAssertTrue(html.contains(picked.key), "HTML lost \(picked.key)")
            XCTAssertTrue(html.contains(picked.name), "HTML lost \(picked.name)")
            XCTAssertTrue(json.contains(picked.key), "JSON lost \(picked.key)")
            XCTAssertTrue(json.contains(picked.name), "JSON lost \(picked.name)")
        }
        for other in unpicked {
            for output in [("HTML", html.lowercased()), ("JSON", json.lowercased())] {
                XCTAssertFalse(output.1.contains(other.key.lowercased()), "\(output.0) holds unpicked key \(other.key)")
                XCTAssertFalse(output.1.contains(other.name.lowercased()), "\(output.0) holds unpicked name \(other.name)")
            }
        }
    }

    func testMetricsFollowThePickerOrder() {
        let result = dashboard([resting, sleep])
        XCTAssertEqual(result.metrics.map(\.key), ["sleep_duration", "resting_heart_rate"])
    }

    // MARK: Missing days

    func testMissingDaysAreOmittedAndNeverZero() throws {
        let result = dashboard([resting])
        XCTAssertEqual(result.metrics[0].values.map(\.date), ["2026-10-20", "2026-10-21", "2026-10-23", "2026-10-25"])
        let (html, json) = try outputs(result)
        XCTAssertFalse(json.contains("2026-10-22"))
        XCTAssertFalse(json.contains("2026-10-24"))
        XCTAssertFalse(json.contains("\"value\" : 0,"))
        XCTAssertFalse(json.contains("\"value\" : 0\n"))
        XCTAssertTrue(html.contains("over 4 days with a reading"))
    }

    func testValuesOutsideThePeriodAndNonFiniteValuesAreDropped() {
        let noisy = series("resting_heart_rate", "Resting heart rate", days: [
            ("2026-08-01", 60), ("2026-10-20", 55), ("2026-10-20", 56), ("2026-10-21", .nan),
            ("2026-10-22", .infinity), ("2026-10-26", 50), ("not-a-day", 40)])
        let result = dashboard([noisy])
        XCTAssertEqual(result.metrics[0].values, [PublishDayValue(date: "2026-10-20", value: 56)])
    }

    func testAMetricWithNoReadingsInThePeriodStaysAndSaysSo() throws {
        let old = series("resting_heart_rate", "Resting heart rate", days: [("2026-01-05", 55)])
        let (html, json) = try outputs(dashboard([old]))
        XCTAssertTrue(html.contains("No readings in this period."))
        XCTAssertTrue(json.contains("resting_heart_rate"))
        XCTAssertFalse(html.contains("<svg"))
    }

    // MARK: Nothing remote

    func testTheHTMLHasNoScriptAddressOrRemoteContent() throws {
        let html = PublishHTMLRenderer.render(dashboard([resting, sleep]))
        for banned in ["<script", "http://", "https://", "src=", "@import", "url(", "<link", "<img", "<iframe", "<form", "href=", "javascript:", "<object", "<embed"] {
            XCTAssertFalse(html.lowercased().contains(banned), "HTML contains \(banned)")
        }
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(html.contains("<meta name=\"color-scheme\" content=\"light dark\">"))
    }

    func testTextIsEscaped() {
        let hostile = series("x", "<b>\"Fast\" & loud</b>", unit: "<i>", days: [("2026-10-24", 1)])
        let html = PublishHTMLRenderer.render(dashboard([hostile]))
        XCTAssertFalse(html.contains("<b>"))
        XCTAssertFalse(html.contains("<i>"))
        XCTAssertTrue(html.contains("&lt;b&gt;&quot;Fast&quot; &amp; loud&lt;/b&gt;"))
    }

    // MARK: Content

    func testEachCardCarriesNameUnitLatestAverageSparklineAndSource() {
        let html = PublishHTMLRenderer.render(dashboard([resting]))
        XCTAssertTrue(html.contains("<h2>Resting heart rate</h2>"))
        XCTAssertTrue(html.contains("<span class=\"value\">53</span>"))
        XCTAssertTrue(html.contains("<span class=\"unit\">bpm</span>"))
        XCTAssertTrue(html.contains("Latest, 25 Oct"))
        XCTAssertTrue(html.contains("Average <strong>53.5</strong>"))
        XCTAssertTrue(html.contains("<svg class=\"spark\""))
        XCTAssertTrue(html.contains("<polyline"))
        XCTAssertTrue(html.contains("Source: Loopr band"))
    }

    func testTheFooterNamesLooprTheExportDateAndTheDeviceLine() {
        let html = PublishHTMLRenderer.render(dashboard([resting]))
        XCTAssertTrue(html.contains("Made with Loopr."))
        XCTAssertTrue(html.contains("Exported 25 Oct 2026."))
        XCTAssertTrue(html.contains("Loopr is not a medical device."))
        XCTAssertTrue(html.contains("Last 30 days, 26 Sep 2026 to 25 Oct 2026"))
    }

    func testAPageWithNoMetricsStillRenders() {
        let html = PublishHTMLRenderer.render(dashboard([]))
        XCTAssertTrue(html.contains("No metrics were picked for this page."))
        XCTAssertTrue(html.contains("Loopr is not a medical device."))
    }

    func testASingleReadingDrawsADotAndNoLine() {
        let one = series("resting_heart_rate", "Resting heart rate", days: [("2026-10-24", 55)])
        let html = PublishHTMLRenderer.render(dashboard([one]))
        XCTAssertTrue(html.contains("<circle"))
        XCTAssertFalse(html.contains("<polyline"))
    }

    func testNumbersUseDotNotationWithoutTrailingZeros() {
        let precise = series("x", "Marker", unit: "mg/dL", group: .bloodTests, days: [("2026-10-24", 0.8), ("2026-10-25", 1234.5)])
        let result = PublishDashboard.make(series: [precise], period: .days30, exportedAt: exportedAt, timeZone: utc, includeBloodTests: true)
        let html = PublishHTMLRenderer.render(result)
        XCTAssertTrue(html.contains("<span class=\"value\">1234</span>") || html.contains("<span class=\"value\">1235</span>"))
        XCTAssertTrue(html.contains("lowest 0.8,"))
    }

    // MARK: Blood tests

    func testBloodTestValuesAppearOnlyWhenSwitchedOn() throws {
        let labs = series("lab_apob", "Apolipoprotein B", unit: "mg/dL", group: .bloodTests, source: "Blood test reports",
                          days: [("2026-10-10", 82)])
        let off = try outputs(dashboard([resting, labs], labs: false))
        XCTAssertFalse(off.html.contains("Apolipoprotein B"))
        XCTAssertFalse(off.json.contains("Apolipoprotein B"))
        XCTAssertFalse(off.json.contains("lab_apob"))
        XCTAssertTrue(off.json.contains("\"includesBloodTests\" : false"))
        let on = try outputs(dashboard([resting, labs], labs: true))
        XCTAssertTrue(on.html.contains("Apolipoprotein B"))
        XCTAssertTrue(on.json.contains("lab_apob"))
        XCTAssertTrue(on.json.contains("\"includesBloodTests\" : true"))
    }

    /// ICP R3-LAB-10: a blood value reads as a draw with its day, not "Average 88 over 1 day with a reading".
    /// ICP R3-UPG-16: minutes read as hours and minutes, as Today shows sleep.
    func testABloodValueIsADrawAndMinutesReadAsHoursAndMinutes() {
        let glucose = series("lab_glucose", "Glucose", unit: "mg/dL", group: .bloodTests, source: "Blood test reports",
                             days: [("2026-10-10", 95), ("2026-10-24", 88)])
        let html = PublishHTMLRenderer.render(dashboard([glucose, sleep], labs: true))
        XCTAssertTrue(html.contains("Drawn 24 Oct"))
        XCTAssertTrue(html.contains("Earlier draws: 95 on 10 Oct"))
        XCTAssertFalse(html.contains("Average <strong>91.5</strong>"))
        XCTAssertTrue(html.contains("<span class=\"value\">7 h 35 min</span>"))
        XCTAssertTrue(html.contains("Average <strong>7 h 28 min</strong>"))
    }

    // MARK: JSON

    func testTheJSONRoundTripsWithItsSchemaVersion() throws {
        let original = dashboard([resting, sleep], period: .days90)
        let data = try PublishJSONRenderer.render(original)
        let decoded = try PublishJSONRenderer.decode(data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.schemaVersion, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        // Foundation names the UTC zone "GMT" on current iOS; both mean the same zone.
        XCTAssertTrue(["UTC", "GMT"].contains(object["timeZone"] as? String ?? ""), "\(object["timeZone"] ?? "nil")")
        XCTAssertEqual(object["exportedAt"] as? String, "2026-10-25T12:00:00Z")
        let period = try XCTUnwrap(object["period"] as? [String: Any])
        XCTAssertEqual(period["id"] as? String, "days90")
        XCTAssertEqual(period["days"] as? Int, 90)
        XCTAssertEqual(period["through"] as? String, "2026-10-25")
        XCTAssertEqual(period["from"] as? String, "2026-07-28")
        let metrics = try XCTUnwrap(object["metrics"] as? [[String: Any]])
        let first = try XCTUnwrap(metrics.first)
        XCTAssertEqual(Set(first.keys), ["key", "name", "unit", "group", "source", "values"])
        let values = try XCTUnwrap(first["values"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(values.first).keys), ["date", "value"])
    }

    // MARK: Period

    func testPeriodsEndOnTheLocalDayOfTheExport() {
        // 02:00 UTC on 25 October is still the evening of the 24th in New York.
        let early = Date(timeIntervalSince1970: 1_792_893_600)
        let newYork = PublishPeriodRange(period: .days30, endingOn: early, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(newYork.through, "2026-10-24")
        XCTAssertEqual(newYork.from, "2026-09-25")
        let perth = PublishPeriodRange(period: .days30, endingOn: early, timeZone: TimeZone(identifier: "Australia/Perth")!)
        XCTAssertEqual(perth.through, "2026-10-25")
        let year = PublishPeriodRange(period: .months12, endingOn: exportedAt, timeZone: utc)
        XCTAssertEqual(year.days, 365)
        XCTAssertEqual(year.from, "2025-10-26")
        XCTAssertTrue(year.contains("2026-02-28"))
        XCTAssertFalse(year.contains("2025-10-25"))
    }

    func testDayLabelsDoCalendarArithmetic() throws {
        XCTAssertEqual(PublishDay.ordinal("1970-01-01"), 0)
        XCTAssertEqual(PublishDay.label(ordinal: try XCTUnwrap(PublishDay.ordinal("2028-02-29")) + 1), "2028-03-01")
        XCTAssertNil(PublishDay.ordinal("2027-02-29"))
        XCTAssertNil(PublishDay.ordinal("2026-13-01"))
        XCTAssertNil(PublishDay.ordinal("26-10-01"))
        XCTAssertEqual(PublishDay.ordinal("2026-10-25"), (PublishDay.ordinal("2026-10-01") ?? 0) + 24)
    }

    // MARK: Files

    func testTheFilesLandInAFolderOfTheirOwnAndAreRemoved() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("PublishFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let stranger = base.appendingPathComponent("keep-me", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)

        let result = dashboard([resting])
        let files = try PublishFileWriter.write(html: PublishHTMLRenderer.render(result),
                                                json: try PublishJSONRenderer.render(result), in: base)
        XCTAssertEqual(files.html.lastPathComponent, "loopr-dashboard.html")
        XCTAssertEqual(files.json.lastPathComponent, "loopr-dashboard.json")
        XCTAssertTrue(files.folder.lastPathComponent.hasPrefix(PublishFileWriter.folderPrefix))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.html.path))
        XCTAssertEqual(try Data(contentsOf: files.json), try PublishJSONRenderer.render(result))

        PublishFileWriter.remove(files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folder.path))

        let left = try PublishFileWriter.write(html: "<p>x</p>", json: Data("{}".utf8), in: base)
        PublishFileWriter.removeStale(in: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }
}
