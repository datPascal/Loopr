import XCTest
import Foundation
import CoachKit
import DomainKit
import ProfileKit
import StorageKit
@testable import Loopr

/// A clock the test moves by hand, shared by the budget and both analytics
/// engines so every interval rule sees the same instant.
private final class OffloadClock: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// What the foreground costs while the band hands over a night of history.
///
/// The band acknowledges a batch about once a second, and every batch moves the
/// day's revision. Four consumers wake on that: the visible screen's catch-up,
/// the widget and Watch snapshot, the Apple Health export and the local coach.
/// Before this was bounded, the phone spent 43 seconds deriving days in ten
/// minutes and iOS filed a 91% CPU report. The rule is one derivation per day
/// per coalescing window, shared by everyone, plus one once the offload stops.
final class HistoryOffloadDerivationTests: XCTestCase {
    private let dayStart: Int64 = 1_788_739_200 // 2026-09-07 00:00 UTC
    private let day = DayIdentity(year: 2026, month: 9, day: 7)
    /// Sixty acknowledged batches, one a second, which is what a multi-hour
    /// backlog looks like from the app's side.
    private let offloadSeconds = 60

    func testAHistoryOffloadIsBoundedToAFewDerivations() async throws {
        let clock = OffloadClock(Date(timeIntervalSince1970: Double(dayStart + 36_000)))
        let budget = LooprDerivationBudget(dates: clock, foreground: LooprFixedForegroundState(true))
        let generations = LooprSharedGenerationCache()
        let (history, productsURL, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNight(history, seconds: 14_401)
        let products = try StorageDatabase(url: productsURL)

        // The screens read one engine; the Apple Health export owns a second
        // for its own civil-day boundaries. Both derive the same days.
        let screens = try makeEngine(history: history, products: products, clock: clock,
                                     budget: budget, generations: generations, namespace: "daily-analytics")
        let export = try makeEngine(history: history, products: products, clock: clock,
                                    budget: budget, generations: generations, namespace: "health-analytics")

        // The first read of a cold day derives it. That is the pass a person is
        // waiting on, and it is never coalesced away.
        let opened = try await screens.readDisplay(day: day, reason: "surface")
        XCTAssertNotNil(opened)
        let openedScreens = await screens.derivationCount
        let openedExport = await export.derivationCount
        XCTAssertGreaterThan(openedScreens + openedExport, 0, "Opening a cold day must derive it once")

        for second in 0..<offloadSeconds {
            try appendSecond(history, at: dayStart + 40_000 + Int64(second))
            await budget.noteHistoryCommit()

            // The widget and Watch snapshot.
            if await budget.claim(.surfaceSnapshot) != nil {
                _ = try await screens.readDisplay(day: day, reason: "surface")
            }
            // The Apple Health export walk.
            if await budget.claim(.healthExport) != nil {
                _ = try await export.read(day: day, reason: "export")
            }
            // The local coach, which Today asks on every reload and which is
            // therefore never gated by the budget.
            _ = try await screens.readCoachInput(day: day)
            // The visible screen's own reload. This is what schedules catch-up.
            _ = try await screens.readDisplay(day: day, reason: "display")

            clock.advance(seconds: 1)
        }
        await drainScheduledPasses()

        let total = await screens.derivationCount + (await export.derivationCount)
        print("[offload] \(offloadSeconds) revisions, four foreground consumers: \(total) derivations")
        // Sixty revisions and four consumers. One derivation per coalescing
        // window is three for the minute; the budget's own foreground interval
        // and the cold open account for the rest. Anything near sixty means a
        // consumer is deriving per batch again.
        XCTAssertLessThanOrEqual(total, 12,
            "A sixty second offload derived \(total) days; the foreground consumers are not coalescing")
        XCTAssertGreaterThan(total, 0)
    }

    /// The coach used to derive today and yesterday itself, uncached, on every
    /// Today reload. It must now cost nothing beyond what the screens paint.
    func testTheCoachReadsTheGenerationTheScreensAlreadyDerived() async throws {
        let clock = OffloadClock(Date(timeIntervalSince1970: Double(dayStart + 36_000)))
        let budget = LooprDerivationBudget(dates: clock, foreground: LooprFixedForegroundState(true))
        let (history, productsURL, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNight(history, seconds: 14_401)
        let engine = try makeEngine(history: history, products: try StorageDatabase(url: productsURL),
                                    clock: clock, budget: budget,
                                    generations: LooprSharedGenerationCache(), namespace: "daily-analytics")

        let display = try await engine.readDisplay(day: day, reason: "surface")
        XCTAssertNotNil(display)
        let derived = await engine.derivationCount

        for _ in 0..<10 {
            let input = try await engine.readCoachInput(day: day)
            XCTAssertNotNil(input, "The coach must see the day the screens are showing")
            XCTAssertFalse(input?.evidence.isEmpty ?? true)
        }
        let after = await engine.derivationCount
        XCTAssertEqual(after, derived, "Ten coach reads derived \(after - derived) days")
    }

    /// The same day, the same revision, three consumers at once. Waiting behind
    /// the derivation lane and then deriving the same thing anyway is what put
    /// surface, export and catch-up in the log inside one second.
    func testConsumersRacingOneRevisionDeriveItOnce() async throws {
        let clock = OffloadClock(Date(timeIntervalSince1970: Double(dayStart + 36_000)))
        let budget = LooprDerivationBudget(dates: clock, foreground: LooprFixedForegroundState(true))
        let generations = LooprSharedGenerationCache()
        let (history, productsURL, root) = try databases()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedNight(history, seconds: 14_401)
        let products = try StorageDatabase(url: productsURL)
        let screens = try makeEngine(history: history, products: products, clock: clock, budget: budget,
                                     generations: generations, namespace: "daily-analytics")
        let export = try makeEngine(history: history, products: products, clock: clock, budget: budget,
                                    generations: generations, namespace: "health-analytics")

        async let surface = screens.read(day: day, reason: "surface")
        async let exported = export.read(day: day, reason: "export")
        async let stress = screens.readStress(day: day, reason: "stress")
        let results = try await (surface, exported, stress)
        XCTAssertNotNil(results.0)
        XCTAssertNotNil(results.1)

        let total = await screens.derivationCount + (await export.derivationCount)
        XCTAssertEqual(total, 1, "One revision must buy one derivation, not \(total)")
    }

    // MARK: Helpers

    /// `readDisplay` schedules its catch-up on a detached task. Let those land
    /// before counting, so the count includes them rather than racing them.
    private func drainScheduledPasses() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func databases() throws -> (StorageDatabase, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (
            try StorageDatabase(url: root.appendingPathComponent("history.sqlite")),
            root.appendingPathComponent("products.sqlite"),
            root
        )
    }

    private func makeEngine(history: StorageDatabase, products: StorageDatabase, clock: OffloadClock,
                            budget: LooprDerivationBudget, generations: LooprSharedGenerationCache,
                            namespace: String) throws -> CanonicalDailyAnalytics {
        try CanonicalDailyAnalytics(
            history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: clock,
            timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!),
            namespace: namespace, budget: budget, sharedGenerations: generations)
    }

    private func seedNight(_ database: StorageDatabase, seconds: Int, heartRate: Int = 55) throws {
        try database.write { db in
            for index in 0..<seconds {
                let timestamp = self.dayStart + Int64(index)
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-07', 24, ?, 0, 0, 1)", arguments: [timestamp, index, timestamp, heartRate])
                let id = db.lastInsertedRowID
                let interval = Int((1_000 + 80 * sin(2 * .pi * 0.25 * Double(index))).rounded())
                try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)", arguments: [id, interval, timestamp * 1_000])
            }
        }
    }

    private func appendSecond(_ database: StorageDatabase, at timestamp: Int64) throws {
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-07', 24, 60, 0, 0, 1)", arguments: [timestamp, 90_000 + timestamp % 1_000, timestamp])
        }
    }
}
