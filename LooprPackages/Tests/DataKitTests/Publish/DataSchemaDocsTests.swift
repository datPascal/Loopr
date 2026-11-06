import DataKit
import StorageKit
import XCTest

/// docs/DATA_SCHEMA.md has to keep up with the code. These tests read the document and the schema it describes.
final class DataSchemaDocsTests: XCTestCase {
    private func document() throws -> String {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = folder.appendingPathComponent("docs/DATA_SCHEMA.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            folder.deleteLastPathComponent()
        }
        throw XCTSkip("docs/DATA_SCHEMA.md is not reachable from the test file path.")
    }

    /// The tables StorageKit requires in every exported database, the same list `requiredTableNames()` builds.
    private var requiredTables: [String] {
        StorageDatabase.requiredLedgerTableNames + Gen5StorageSchema.tableNames + ["release_action_audit"]
            + FoodStorageSchema.tableNames + TrainStorageSchema.tableNames + RoutineStorageSchema.tableNames
            + LabStorageSchema.tableNames + SupplementStorageSchema.tableNames + CapacityStorageSchema.tableNames
            + ExperimentStorageSchema.tableNames
    }

    /// Tables that other packages create on the same files, outside StorageKit's required list.
    private let otherTables = ["loopr_product_document", "profile", "profile_units", "profile_goals",
                               "whoop_export_row", "whoop_export_day", "whoop_export_workout", "whoop_export_journal"]

    func testEveryRequiredTableIsNamedInTheDocument() throws {
        let text = try document()
        for table in requiredTables {
            XCTAssertTrue(text.contains("`\(table)`"), "docs/DATA_SCHEMA.md does not name the table \(table)")
        }
    }

    func testTablesFromOtherPackagesAreNamedToo() throws {
        let text = try document()
        for table in otherTables {
            XCTAssertTrue(text.contains("`\(table)`"), "docs/DATA_SCHEMA.md does not name the table \(table)")
        }
    }

    func testEveryTableOfAFreshDatabaseIsNamedInTheDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DataSchemaDocsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("docs.sqlite"), applicationVersion: "docs-tests")
        let text = try document()
        for table in try database.tableNames().sorted() where !table.hasPrefix("sqlite_") {
            XCTAssertTrue(text.contains("`\(table)`"), "docs/DATA_SCHEMA.md does not name the table \(table)")
        }
    }

    func testEveryColumnOfEveryRequiredTableIsNamedInTheDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DataSchemaDocsColumns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("docs.sqlite"), applicationVersion: "docs-tests")
        let text = try document()
        for table in requiredTables {
            // A table's section runs from its heading to the next heading of the same level.
            guard let start = text.range(of: "#### `\(table)`") else {
                XCTFail("docs/DATA_SCHEMA.md has no section for \(table)")
                continue
            }
            let rest = text[start.upperBound...]
            let section = rest.range(of: "\n#").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            let columns: [String] = try database.read { db in try db.columns(in: table).map(\.name) }
            for column in columns {
                XCTAssertTrue(section.contains("`\(column)`"), "the section for \(table) does not name the column \(column)")
            }
        }
    }

    func testTheDocumentNamesTheExportManifestKeysAndTheVersion() throws {
        let text = try document()
        for key in ["formatVersion", "createdAt", "kind", "databases", "tables", "json", "csv", "excluded", "consistency",
                    "manifest.json", "preferences.plist", "photos"] {
            XCTAssertTrue(text.contains("`\(key)`") || text.contains(key), "the document does not mention \(key)")
        }
        XCTAssertTrue(text.contains("`formatVersion`: `1`"), "the document must state format version 1")
    }

    func testTheDocumentDescribesTheDashboardJSON() throws {
        let text = try document()
        for key in ["schemaVersion", "generator", "exportedAt", "timeZone", "period", "includesBloodTests", "metrics",
                    "key", "name", "unit", "group", "source", "values", "date", "value", "loopr-dashboard.json", "loopr-dashboard.html"] {
            XCTAssertTrue(text.contains("`\(key)`") || text.contains(key), "the document does not mention \(key)")
        }
        XCTAssertTrue(text.contains("Schema version \(PublishDashboard.currentSchemaVersion)"))
    }

    func testTheDocumentUsesNoEmDash() throws {
        XCTAssertFalse(try document().contains("\u{2014}"))
    }
}
