import XCTest
@testable import StorageKit

final class ExportDeletionAuditTests: XCTestCase {
    func testExportAndDeletionRequireConfirmationAndWriteTimestampedScopes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-audit-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try StorageDatabase(url: url, applicationVersion: "test")
        let audit = ReleaseActionAuditStore(database: database)
        let now = Date(timeIntervalSince1970: 1_787_472_000)

        XCTAssertThrowsError(try audit.record(.export, scope: "full-database", performedAt: now, userConfirmed: false))
        XCTAssertTrue(try audit.rows().isEmpty)

        try audit.record(.export, scope: "full-database", performedAt: now, userConfirmed: true)
        try audit.record(.deletion, scope: "all-loopr-owned-data", performedAt: now.addingTimeInterval(1), userConfirmed: true)

        let rows = try audit.rows()
        XCTAssertEqual(rows.map(\.action), [.export, .deletion])
        XCTAssertEqual(rows.map(\.scope), ["full-database", "all-loopr-owned-data"])
        XCTAssertEqual(rows.map(\.performedAt), [now, now.addingTimeInterval(1)])
    }

    func testFullDeletionClearsItsOwnPreflightAuditEntry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-audit-clear-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try StorageDatabase(url: url, applicationVersion: "test")
        let audit = ReleaseActionAuditStore(database: database)
        try audit.record(
            .deletion,
            scope: "all-loopr-owned-data",
            performedAt: Date(timeIntervalSince1970: 1_787_472_000),
            userConfirmed: true
        )
        XCTAssertEqual(try audit.rows().count, 1)

        try database.deleteAllData()

        XCTAssertTrue(try audit.rows().isEmpty, "full deletion must not retain its own audit ledger")
    }
}
