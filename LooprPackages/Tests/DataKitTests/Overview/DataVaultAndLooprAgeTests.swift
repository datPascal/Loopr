import AnalyticsKit
@testable import DataKit
import Foundation
import StorageKit
import XCTest

/// The vault card and meta read real databases and real counts, and Loopr Age is never a number.
final class DataVaultAndLooprAgeTests: XCTestCase {
    private typealias S = DataOverviewTestSupport
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func makeDatabase(_ name: String) throws -> StorageDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DataVaultTests-\(UUID().uuidString)")
        roots.append(root)
        return try StorageDatabase(url: root.appendingPathComponent("\(name).sqlite"), applicationVersion: "data-vault-tests")
    }

    // MARK: Vault

    func testTheSchemaVersionIsTheNumberOfTheNewestMigration() {
        XCTAssertEqual(DataVaultReader.schemaNumber("storage-021-experiments"), 21)
        XCTAssertEqual(DataVaultReader.schemaNumber("storage-001-schema-metadata"), 1)
        XCTAssertNil(DataVaultReader.schemaNumber("v2-something"))
        XCTAssertNil(DataVaultReader.schemaNumber("storage-x"))
    }

    func testTheVaultReadsSizeDaysAndSchemaFromTheDatabases() throws {
        let products = try makeDatabase("products")
        let history = try makeDatabase("history")
        try history.write { db in
            for (day, source) in [("2025-09-01", "band"), ("2025-09-02", "band"), ("2025-09-02", "apple_health"), ("2026-10-24", "band")] {
                try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, source, value, updated_at) VALUES (?, 'rmssd', ?, 60, 0)",
                               arguments: [day, source])
            }
        }
        try products.write { db in
            try db.execute(sql: "INSERT INTO metric_series(local_day, metric_key, source, value, updated_at) VALUES ('2025-08-30', 'steps', 'apple_health', 9000, 0)")
        }
        let facts = try DataVaultReader.read([products, history])
        XCTAssertEqual(facts.daysOfData, 4)
        XCTAssertEqual(facts.firstDay, "2025-08-30")
        let newest = StorageMigrations.makeMigrator(applicationVersion: "x").migrations.compactMap(DataVaultReader.schemaNumber).max()
        XCTAssertEqual(facts.schemaVersion, newest)
        XCTAssertNotNil(facts.schemaVersion)
        XCTAssertGreaterThan(facts.fileBytes, 0)
        XCTAssertEqual(facts.importedDays, 0)
    }

    /// ICP R2-LAB-16: no schema number or file format on the card, and the size in the person's locale.
    func testTheFileCardNamesTodaysDateTheSizeAndTheDays() {
        let english = Locale(identifier: "en_US"), german = Locale(identifier: "de_DE")
        let facts = DataVaultFacts(fileBytes: 2_700_000, daysOfData: 412, schemaVersion: 21)
        let card = DataVaultCard.make(facts: facts, now: S.date(2026, 10, 23, hour: 23), calendar: S.calendar, locale: english)
        XCTAssertEqual(card.fileName, "loopr-2026-10-23.sqlite")
        XCTAssertEqual(card.detail, "Storage on this iPhone: \(Int64(2_700_000).formatted(.byteCount(style: .file).locale(english))) · 412 days of data")
        XCTAssertTrue(card.detail.contains("2.7"), card.detail)
        XCTAssertFalse(card.detail.contains("schema") || card.detail.lowercased().contains("sqlite"), card.detail)
        XCTAssertTrue(DataVaultCard.make(facts: facts, now: S.drawn, calendar: S.calendar, locale: german).detail.contains("2,7"))
        XCTAssertTrue(DataVaultCard.make(facts: DataVaultFacts(daysOfData: 1), now: S.drawn, calendar: S.calendar).detail.hasSuffix("1 day of data"))
        XCTAssertTrue(DataVaultCard.make(facts: DataVaultFacts(), now: S.drawn, calendar: S.calendar).detail.hasSuffix("no days of data yet"))
    }

    func testTheMetaAndTheSourceRowsCountWhatIsThere() {
        let now = S.date(2026, 10, 25)
        let facts = DataSourceFacts(bandName: "WHOOP 4.0", bandLastSync: now.addingTimeInterval(-120),
                                    appleHealthSources: ["Apple Watch", "Withings", "Oura"],
                                    appleHealthKinds: ["VO₂max", "daylight", "weight"],
                                    labReports: 2, labValues: 43, labNames: ["Riverside Lab", "riverside lab ", nil], importedDays: 30)
        // Band 1, three Apple Health sources, two labs (unnamed reports count as one), the WHOOP export 1.
        XCTAssertEqual(facts.sourceCount, 7)
        XCTAssertEqual(DataVaultMeta.line(facts: DataVaultFacts(daysOfData: 412), sources: facts), "412 days · 7 sources · all on this iPhone")
        XCTAssertEqual(DataVaultMeta.line(facts: nil, sources: facts), "All on this iPhone")
        // ICP R1-NEW-24: no stored day, no counts.
        XCTAssertEqual(DataVaultMeta.line(facts: DataVaultFacts(daysOfData: 0), sources: DataSourceFacts()), "No data yet · all on this iPhone")
        // ICP R3-LAB-6: with blood tests but no stored day, the header counts the blood tests, not "No data yet".
        XCTAssertEqual(DataVaultMeta.line(facts: DataVaultFacts(daysOfData: 0), sources: facts), "2 blood tests · all on this iPhone")

        let rows = DataSourceRow.rows(facts, now: now)
        XCTAssertEqual(rows.map(\.kind), [.band, .appleHealth, .labs, .whoopExport])
        XCTAssertEqual(rows[0].text, "WHOOP 4.0 · synced 2 min ago")
        XCTAssertEqual(rows[1].text, "Apple Health · VO₂max, daylight and weight from Apple Watch, Withings and Oura")
        XCTAssertEqual(rows[2].text, "2 lab reports · 43 values")
        XCTAssertEqual(rows[3].text, "WHOOP account export · 30 days")
        XCTAssertEqual(rows.map(\.kind.identifier), ["data-source-band", "data-source-apple-health", "data-source-labs", "data-source-whoop-export"])

        let empty = DataSourceFacts()
        XCTAssertEqual(empty.sourceCount, 0)
        XCTAssertEqual(DataSourceRow.rows(empty, now: now).map(\.text), ["No band paired", "Apple Health · nothing read yet", "No lab reports yet"])
        XCTAssertEqual(DataSourceRow.rows(DataSourceFacts(appleHealthSwitchedOff: true), now: now)[1].text, "Apple Health · reads switched off")
        // More than three apps: two by name and how many more. A kind without a named source lists no apps.
        XCTAssertEqual(DataSourceRow.rows(DataSourceFacts(appleHealthSources: ["Apple Watch", "Withings", "Oura", "Garmin"],
                                                          appleHealthKinds: ["steps"]), now: now)[1].text,
                       "Apple Health · steps from Apple Watch, Withings and 2 more")
        XCTAssertEqual(DataSourceRow.rows(DataSourceFacts(appleHealthKinds: ["weight"]), now: now)[1].text, "Apple Health · weight")
        XCTAssertEqual(DataVaultMeta.line(facts: DataVaultFacts(daysOfData: 1), sources: DataSourceFacts(bandName: "WHOOP 4.0")),
                       "1 day · 1 source · all on this iPhone")
    }

    func testTheOverviewPutsItAllTogetherFromItsInputs() {
        let now = S.drawn.addingTimeInterval(43 * 86_400)
        let overview = DataOverview.make(DataOverviewInput(
            now: now, calendar: S.calendar, birthYear: 1988, referenceGroup: .male, labDraws: [S.completeDraw()],
            vo2Max: .readings(S.vo2Readings(now: now)), series: [S.series("rmssd", points: [])],
            vault: DataVaultFacts(fileBytes: 1_000, daysOfData: 3, schemaVersion: 21),
            sources: DataSourceFacts(bandName: "WHOOP 4.0", labReports: 1, labValues: 9, labNames: ["Riverside Lab"])))
        XCTAssertEqual(overview.ruler.pins.map(\.kind), [.blood, .real, .cardio])
        XCTAssertEqual(overview.starMap.count, LabMarkerCatalog.markers.count + 1)
        XCTAssertEqual(overview.meta, "3 days · 2 sources · all on this iPhone")
        XCTAssertEqual(overview.vaultCard?.fileName, "loopr-2026-10-25.sqlite")
        XCTAssertEqual(overview.slopes, .learning(daysUntilOpen: 365 - 43))
    }

    // MARK: Loopr Age

    func testTheLockedLooprAgeTileNeverShowsANumber() {
        for text in [DataLooprAgeTile.title, DataLooprAgeTile.line, DataLooprAgeTile.spokenLabel, DataLooprAgeTile.hint] {
            XCTAssertFalse(text.contains { $0.isNumber }, text)
        }
        XCTAssertEqual(DataLooprAgeTile.line, "Not shown until it is tested on people it was not built from.")
        // The ruler has no Loopr Age pin, and nothing the overview holds is named for it.
        XCTAssertFalse(DataAgePinKind.allCases.contains { $0.rawValue.lowercased().contains("loopr") })
        let now = S.drawn.addingTimeInterval(43 * 86_400)
        let overview = DataOverview.make(DataOverviewInput(now: now, calendar: S.calendar, birthYear: 1988, referenceGroup: .male,
                                                           labDraws: [S.completeDraw()], vo2Max: .readings(S.vo2Readings(now: now))))
        XCTAssertFalse(overview.ruler.spokenSummary.contains("Loopr Age"))
        XCTAssertFalse(overview.ruler.hero.spokenLabel.contains("Loopr Age"))
        XCTAssertFalse(Mirror(reflecting: overview).children.contains { ($0.label ?? "").lowercased().contains("loopr") })
        XCTAssertFalse(Mirror(reflecting: overview.ruler).children.contains { ($0.label ?? "").lowercased().contains("loopr") })
    }

    func testThePlanInTheAppFollowsTheStagesOfLooprAgeMarkdown() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let document = try String(contentsOf: root.appendingPathComponent(DataLooprAgePlan.sourcePath), encoding: .utf8)
        let headings = document.split(separator: "\n").filter { $0.hasPrefix("### Stage ") }.map { line in
            String(line.dropFirst("### Stage ".count))
        }
        XCTAssertEqual(headings.count, DataLooprAgePlan.stages.count)
        for (heading, stage) in zip(headings, DataLooprAgePlan.stages) {
            XCTAssertEqual(heading.lowercased(), "\(stage.letter): \(stage.title)".lowercased())
        }
        XCTAssertFalse(DataLooprAgePlan.intro.contains("—"))
    }

    /// ICP R2-LAB-15: the page is for a person. No stage letters, no source path, and no claim that an age is on the
    /// ruler when none is.
    func testThePlanPageSpeaksToAPersonNotToTheTeam() {
        let shown = [DataLooprAgePlan.intro, DataLooprAgePlan.whyLocked, DataLooprAgePlan.stagesHeader, DataLooprAgePlan.otherAges]
            + DataLooprAgePlan.stages.map(\.step)
        for text in shown {
            XCTAssertFalse(text.contains(".md") || text.contains("docs/") || text.contains("Stage "), text)
            XCTAssertFalse(text.contains("—") || text.contains("\""), text)
        }
        XCTAssertFalse(DataLooprAgePlan.otherAges.contains("already"))
        XCTAssertTrue(DataLooprAgePlan.otherAges.contains("once you have"))
    }
}
