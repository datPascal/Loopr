import AIKit
import DomainKit
import Foundation
import StorageKit
import TodayKit
import XCTest
@testable import Loopr

@MainActor
final class CoachProductionDatabaseTests: XCTestCase {
    func testCurrentSchemaSupportsTodayAndCoachTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try StorageDatabase(url: root.appendingPathComponent("Loopr/loopr.sqlite"))
        let now = Date()
        let timestamp = Int64(now.timeIntervalSince1970) - 60
        try history.write { db in
            try db.execute(sql: """
                INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp,
                    local_day, record_version, heart_rate, unidentified_68, skin_temperature_celsius)
                VALUES (?, 1, ?, ?, 24, 65, 700, 35)
                """, arguments: [timestamp, timestamp, LooprCoachContextBuilder.dayString(now)])
        }
        try await validate(root: root, now: now)
    }

    /// Opt-in hardware regression. Only copied SQLite files are read and all
    /// derivations run on another disposable copy. No health values are logged.
    #if LOOPR_PRIVATE_DATABASE_AUDITS
    func testExportedDeviceDatabaseLoadsTodayAndCoach() async throws {
        let sourcePath = try XCTUnwrap(ProcessInfo.processInfo.environment["LOOPR_COACH_DEVICE_SNAPSHOT"],
            "Set LOOPR_COACH_DEVICE_SNAPSHOT to a local Application Support export.")
        let source = URL(fileURLWithPath: sourcePath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Loopr"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["Loopr.sqlite", "Loopr/loopr.sqlite"] {
            for suffix in ["", "-wal", "-shm"] {
                let original = source.appendingPathComponent(file + suffix)
                if suffix.isEmpty || FileManager.default.fileExists(atPath: original.path) {
                    try FileManager.default.copyItem(at: original, to: root.appendingPathComponent(file + suffix))
                }
            }
        }
        try await validate(root: root, now: Date())
    }
    #endif

    private func validate(root: URL, now: Date) async throws {
        let suite = "LooprCoachDatabaseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let environment = AppEnvironment(composition: .production, root: .main,
            storageURL: root.appendingPathComponent("Loopr.sqlite"), applicationVersion: "coach-regression",
            dateProvider: SystemDateProvider(), calendarProvider: SystemCalendarProvider(),
            timeZoneProvider: SystemTimeZoneProvider(), uuidProvider: SystemUUIDProvider(), scheduler: SystemScheduler())
        let repositories = try PersistentProductRepositories(environment: environment, defaults: defaults)
        let day = environment.productDay(fixture: TodayFixtures.day)
        let before = try recordCounts(repositories.historyDatabase)
        let model = TodayViewModel(repository: repositories.today, goalsRepository: repositories.todayGoals,
                                   coachPlanRepository: repositories.coach)
        await model.load(day: day)
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertNotNil(model.summary)
        let sleep = try await repositories.sleep.readSleepDay(for: day)
        let heart = try await repositories.heart.readHeartDay(for: day)
        let body = try await repositories.body.readBodyDay(for: day)
        XCTAssertNotNil(sleep); XCTAssertNotNil(heart); XCTAssertNotNil(body)
        let summary = try await LooprCoachContextBuilder(repositories: repositories).summary(sharing: .init(), at: now)
        XCTAssertFalse(summary.isEmpty)
        let chats = try SQLiteCoachConversationRepository(database: repositories.database)
        let preferences = try await chats.preferences()
        XCTAssertFalse(preferences.morningEnabled)
        XCTAssertEqual(try recordCounts(repositories.historyDatabase), before)
        try await repositories.analytics.deleteAll()
    }

    private func recordCounts(_ database: StorageDatabase) throws -> [Int] {
        try database.read { db in
            try [Int.fetchOne(db, sql: "SELECT COUNT(*) FROM decoded_second") ?? 0,
                 Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rr_beat") ?? 0]
        }
    }
}
