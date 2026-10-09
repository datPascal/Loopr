import XCTest
import Foundation
import DomainKit
import ProfileKit
import StorageKit
@testable import Loopr

/// A clock the test moves by hand. Every budget rule is a time comparison, so
/// nothing here waits on a real one.
private final class SteppedClock: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// Counts how many holders were inside the lane at the same time. One is the
/// only acceptable answer: two days deriving on two cores is what iOS killed
/// Loopr for.
private actor ConcurrencyWitness {
    private var current = 0
    private(set) var peak = 0

    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

/// The CPU budget that stands between a band syncing around the clock and the
/// 80%-over-60-seconds limit iOS enforces on a background app.
final class DerivationBudgetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_788_739_200)

    private func makeBudget(foreground: Bool, clock: SteppedClock) -> LooprDerivationBudget {
        LooprDerivationBudget(dates: clock, foreground: LooprFixedForegroundState(foreground))
    }

    // MARK: Off screen

    func testManyRevisionsInOneWindowBuyOneBackgroundPass() async throws {
        let clock = SteppedClock(start)
        let budget = makeBudget(foreground: false, clock: clock)

        // Twenty acknowledged batches a minute apart: one band top-up, and the
        // next one starting.
        clock.advance(seconds: LooprDerivationBudget.coldStartQuietSeconds)
        var granted = 0
        for _ in 0..<20 {
            await budget.noteHistoryCommit()
            let grant = await budget.claim(.healthExport)
            if grant != nil { granted += 1 }
            clock.advance(seconds: 60)
        }
        XCTAssertEqual(granted, 1, "Twenty commits inside one half-hour window must buy one pass")

        // Past the window, with new history, one more is earned.
        clock.advance(seconds: LooprDerivationBudget.backgroundIntervalSeconds)
        await budget.noteHistoryCommit()
        let later = await budget.claim(.healthExport)
        XCTAssertNotNil(later)
    }

    func testOffScreenWorkNeverRunsWithoutNewHistory() async throws {
        let clock = SteppedClock(start)
        let budget = makeBudget(foreground: false, clock: clock)
        // A whole night off screen with nothing arriving from the band.
        for _ in 0..<8 {
            let grant = await budget.claim(.surfaceSnapshot)
            XCTAssertNil(grant)
            clock.advance(seconds: 3_600)
        }
    }

    func testEachConsumerKeepsItsOwnAllowance() async throws {
        let clock = SteppedClock(start)
        let budget = makeBudget(foreground: false, clock: clock)
        clock.advance(seconds: LooprDerivationBudget.coldStartQuietSeconds)
        await budget.noteHistoryCommit()

        let export = await budget.claim(.healthExport)
        XCTAssertNotNil(export)
        let surface = await budget.claim(.surfaceSnapshot)
        XCTAssertNotNil(surface, "The export must not spend the widget's pass")
        let again = await budget.claim(.healthExport)
        XCTAssertNil(again)
    }

    func testAProcessingWindowMayIgnoreTheInterval() async throws {
        let clock = SteppedClock(start)
        let budget = makeBudget(foreground: false, clock: clock)
        clock.advance(seconds: LooprDerivationBudget.coldStartQuietSeconds)
        await budget.noteHistoryCommit()
        let first = await budget.claim(.healthExport)
        XCTAssertNotNil(first)

        await budget.noteHistoryCommit()
        let insideWindow = await budget.claim(.healthExport)
        XCTAssertNil(insideWindow, "Still inside the half hour")

        await budget.beginProcessingWindow()
        let processing = await budget.claim(.healthExport)
        XCTAssertNotNil(processing, "iOS picked this moment, so take it")
        await budget.endProcessingWindow()

        await budget.noteHistoryCommit()
        let afterWindow = await budget.claim(.healthExport)
        XCTAssertNil(afterWindow)
    }

    // MARK: On screen

    func testAForegroundBurstIsBoundedByTheMinuteSpacing() async throws {
        let clock = SteppedClock(start)
        let budget = makeBudget(foreground: true, clock: clock)

        // Five minutes of live streaming: a second lands every second and each
        // one bumps the data revision.
        var granted = 0
        for _ in 0..<300 {
            await budget.noteHistoryCommit()
            let grant = await budget.claim(.dayDisplay)
            if grant != nil { granted += 1 }
            clock.advance(seconds: 1)
        }
        XCTAssertEqual(granted, 5, "Three hundred seconds at a minute apiece is five passes")
    }

    func testOnScreenWorkDoesNotWaitForNewHistory() async throws {
        let clock = SteppedClock(start)
        let budget = makeBudget(foreground: true, clock: clock)
        let grant = await budget.claim(.dayDisplay)
        XCTAssertNotNil(grant, "Opening a tab must never be blocked")
    }

    // MARK: The lane

    func testNothingEverDerivesInParallel() async throws {
        let budget = makeBudget(foreground: true, clock: SteppedClock(start))
        let witness = ConcurrencyWitness()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    guard await budget.beginDerivation() else { return }
                    await witness.enter()
                    // Long enough that an unserialized lane would overlap.
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    await witness.leave()
                    await budget.endDerivation(seconds: 0.002)
                }
            }
        }
        let peak = await witness.peak
        XCTAssertEqual(peak, 1, "Two derivations at once is what got the app killed")
        let busy = await budget.laneIsBusy
        XCTAssertFalse(busy, "The lane must be free once every holder has released it")
    }

    func testACancelledDerivationDoesNotStrandTheLane() async throws {
        let budget = makeBudget(foreground: true, clock: SteppedClock(start))

        // Take the lane here rather than from a task. Two tasks racing for it
        // is not the same test: when the waiter won, it took the lane and
        // returned without ever releasing it, the holder polled a lane nobody
        // would hand over, and with a clock this test never advances the wait
        // limit could not fire either. That hung the whole suite.
        let held = await budget.beginDerivation()
        XCTAssertTrue(held, "A free lane must be grantable on screen")
        let holder = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await budget.endDerivation(seconds: 0.05)
        }
        // Queue behind it, then cancel while it is still waiting.
        let waiter = Task { _ = await budget.beginDerivation() }
        try await Task.sleep(nanoseconds: 10_000_000)
        waiter.cancel()
        _ = await waiter.value
        await holder.value

        let busy = await budget.laneIsBusy
        XCTAssertFalse(busy, "A cancelled waiter used to hold the lane for the life of the process")
        let granted = await budget.beginDerivation()
        XCTAssertTrue(granted, "The lane has to be usable again")
        await budget.endDerivation(seconds: 0)
    }

    // MARK: The rolling CPU ceiling

    /// The device numbers: a Debug derive of one worn day costs about fifteen
    /// seconds on the phone, and iOS kills at 80% of sixty seconds.
    private static let deviceDeriveSeconds: TimeInterval = 15

    func testAColdBackgroundLaunchDerivesNothingForItsFirstMinutes() async throws {
        let clock = SteppedClock(start)
        let budget = makeBudget(foreground: false, clock: clock)
        await budget.noteHistoryCommit()

        // iOS relaunches Loopr for its restored Bluetooth central and the band
        // commits straight away. This is the launch that kept getting killed.
        for _ in 0..<29 {
            let mayDerive = await budget.canDerive()
            XCTAssertFalse(mayDerive, "A cold background launch must derive nothing")
            let began = await budget.beginDerivation()
            XCTAssertFalse(began)
            let claim = await budget.claim(.surfaceSnapshot)
            XCTAssertNil(claim, "Not even the snapshot pass may start")
            clock.advance(seconds: 10)
        }

        clock.advance(seconds: LooprDerivationBudget.coldStartQuietSeconds)
        let settled = await budget.canDerive()
        XCTAssertTrue(settled, "Once the launch has settled, one day may be derived")
    }

    func testTotalDeriveTimeInAnyRollingMinuteStaysUnderTheCeiling() async throws {
        let clock = SteppedClock(start)
        let budget = makeBudget(foreground: false, clock: clock)
        // Past the cold start, with the band topping up throughout.
        clock.advance(seconds: LooprDerivationBudget.coldStartQuietSeconds)

        var runs: [(start: Date, end: Date, seconds: TimeInterval)] = []
        // Half an hour of background life, asking every second, as the
        // publisher, the export and a prior-day walk all would.
        for tick in 0..<1_800 {
            if tick % 60 == 0 { await budget.noteHistoryCommit() }
            _ = await budget.claim(.surfaceSnapshot)
            _ = await budget.claim(.healthExport)
            if await budget.beginDerivation() {
                let began = clock.now()
                clock.advance(seconds: Self.deviceDeriveSeconds)
                await budget.endDerivation(seconds: Self.deviceDeriveSeconds)
                runs.append((began, clock.now(), Self.deviceDeriveSeconds))
            } else {
                clock.advance(seconds: 1)
            }
        }

        XCTAssertFalse(runs.isEmpty, "Some work still has to get done")

        // The number iOS measures: CPU seconds inside any sixty second window.
        var worst: TimeInterval = 0
        for offset in stride(from: 0.0, through: 1_800, by: 1) {
            let from = start.addingTimeInterval(LooprDerivationBudget.coldStartQuietSeconds + offset)
            let to = from.addingTimeInterval(LooprDerivationBudget.rollingWindowSeconds)
            let total = runs.reduce(0.0) { sum, run in
                sum + max(0, min(run.end, to).timeIntervalSince(max(run.start, from)))
            }
            worst = max(worst, total)
        }
        let minutes = 1_800.0 / 60
        print(String(format: "[budget] %d derivations in %.0f minutes off screen; worst rolling minute %.1f s (%.0f%% CPU)",
                     runs.count, minutes, worst, worst / LooprDerivationBudget.rollingWindowSeconds * 100))
        XCTAssertLessThanOrEqual(
            worst, LooprDerivationBudget.backgroundRollingBudgetSeconds,
            "The worst rolling minute spent \(worst) s deriving; iOS kills at 48 s"
        )
    }

    func testAProcessingWindowHasAHigherCeilingButStillHasOne() async throws {
        let clock = SteppedClock(start)
        let budget = makeBudget(foreground: false, clock: clock)
        clock.advance(seconds: LooprDerivationBudget.coldStartQuietSeconds)
        await budget.beginProcessingWindow()

        var spent: TimeInterval = 0
        for _ in 0..<10 {
            guard await budget.beginDerivation() else { break }
            clock.advance(seconds: 5)
            await budget.endDerivation(seconds: 5)
            spent += 5
        }
        XCTAssertGreaterThan(spent, LooprDerivationBudget.backgroundRollingBudgetSeconds,
                             "A window iOS handed us is worth more than the ordinary allowance")
        XCTAssertLessThanOrEqual(spent, LooprDerivationBudget.processingRollingBudgetSeconds,
                                 "It is still a ceiling")
        await budget.endProcessingWindow()
    }

    // MARK: The analytics actor

    func testAStaleDayIsNotCaughtUpWhileLooprIsOffScreen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let clock = SteppedClock(fixture.now)
        let onScreen = try fixture.engine(clock: clock, budget: makeBudget(foreground: true, clock: clock))
        let first = try await onScreen.readDisplay(day: fixture.day)
        XCTAssertNotNil(first)
        let derived = await onScreen.derivationCount
        XCTAssertGreaterThan(derived, 0)

        try fixture.appendSecond(at: fixture.dayStart + 20_000)

        let offScreenClock = SteppedClock(fixture.now)
        let offScreen = try fixture.engine(
            clock: offScreenClock,
            budget: makeBudget(foreground: false, clock: offScreenClock)
        )
        let painted = try await offScreen.readDisplay(day: fixture.day)
        XCTAssertNotNil(painted, "The finished generation still paints")
        for _ in 0..<50 { await Task.yield() }
        let offScreenDerivations = await offScreen.derivationCount
        XCTAssertEqual(offScreenDerivations, 0, "Nobody is looking, so nothing may be derived")
    }

    func testTheVisibleDayIsCaughtUpAtMostOncePerMinute() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let clock = SteppedClock(fixture.now)
        let engine = try fixture.engine(clock: clock, budget: makeBudget(foreground: true, clock: clock))
        let opened = try await engine.readDisplay(day: fixture.day)
        XCTAssertNotNil(opened)
        let afterFirst = await engine.derivationCount

        // One new second, as arrives every second while the band streams.
        try fixture.appendSecond(at: fixture.dayStart + 20_000)
        let stale = try await engine.readDisplay(day: fixture.day)
        XCTAssertNotNil(stale)
        await engine.waitForScheduledRefresh(day: fixture.day)
        let caughtUp = await engine.derivationCount
        XCTAssertGreaterThan(caughtUp, afterFirst)
        let afterCatchUp = await engine.derivationCount

        // Sixty more seconds land while the clock stays put. Not one of them
        // may buy another pass.
        for offset in 1...60 {
            try fixture.appendSecond(at: fixture.dayStart + 20_000 + Int64(offset))
            let painted = try await engine.readDisplay(day: fixture.day)
            XCTAssertNotNil(painted)
        }
        for _ in 0..<50 { await Task.yield() }
        let afterBurst = await engine.derivationCount
        XCTAssertEqual(afterBurst, afterCatchUp, "Sixty inserted seconds are not sixty derivations")

        // A minute later the day is allowed to catch up again.
        clock.advance(seconds: LooprDerivationBudget.foregroundIntervalSeconds + 1)
        let reopened = try await engine.readDisplay(day: fixture.day)
        XCTAssertNotNil(reopened)
        await engine.waitForScheduledRefresh(day: fixture.day)
        let laterCatchUp = await engine.derivationCount
        XCTAssertGreaterThan(laterCatchUp, afterBurst)
    }

    func testEveryDerivationLeavesOneLineForTheOvernightAudit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let clock = SteppedClock(fixture.now)
        let budget = makeBudget(foreground: false, clock: clock)
        // Past the cold start, so the off-screen pass is actually allowed to
        // run and leave its line.
        clock.advance(seconds: LooprDerivationBudget.coldStartQuietSeconds)
        let engine = try fixture.engine(clock: clock, budget: budget)

        #if DEBUG
        // The app delegate already writes stderr to this file. Redirecting
        // the guarded descriptor crashes the test host on iOS 26.
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw XCTSkip("The debug log directory is unavailable")
        }
        let logURL = caches.appendingPathComponent("loopr-debug.log")
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            throw XCTSkip("The app did not open its debug log")
        }
        let start = try Data(contentsOf: logURL).count
        #endif
        let display = try await engine.readDisplay(day: fixture.day)
        XCTAssertNotNil(display)

        #if DEBUG
        let data = try Data(contentsOf: logURL)
        let trace = String(decoding: data.suffix(from: min(start, data.count)), as: UTF8.self)
        let lines = trace.split(separator: "\n").filter { $0.contains("[Loopr Analytics]") }
        guard let first = lines.first else {
            return XCTFail("A derivation with no trace cannot be audited")
        }
        let line = String(first)
        XCTAssertTrue(line.contains("derive day=2026-09-07"), line)
        XCTAssertTrue(line.contains("reason="), line)
        XCTAssertTrue(line.contains("ms="), line)
        XCTAssertTrue(line.contains("background=true"), line)
        #endif
    }

    func testTheTwoEnginesDeriveOneDayBetweenThemRatherThanOneEach() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let clock = SteppedClock(fixture.now)
        let budget = makeBudget(foreground: true, clock: clock)

        // The screens' engine and the Apple Health export engine. They persist
        // to different namespaces, which is why each used to derive every day.
        let screens = try fixture.engine(clock: clock, budget: budget)
        let export = try fixture.engine(clock: clock, budget: budget, namespace: "health-export-analytics")

        let painted = try await screens.readDisplay(day: fixture.day)
        XCTAssertNotNil(painted)
        let screenDerivations = await screens.derivationCount
        XCTAssertGreaterThan(screenDerivations, 0)

        let exported = try await export.read(day: fixture.day, reason: "export")
        XCTAssertNotNil(exported, "The export still gets the day")
        let exportDerivations = await export.derivationCount
        XCTAssertEqual(exportDerivations, 0, "The second engine must reuse the first engine's generation")
    }

    // MARK: Helpers

    /// One recorded night in a throwaway pair of databases.
    private struct Fixture {
        let dayStart: Int64 = 1_788_739_200 // 2026-09-07 00:00 UTC
        let day = DayIdentity(year: 2026, month: 9, day: 7)
        let root: URL
        let history: StorageDatabase
        let productsURL: URL
        /// Fresh per fixture, so one case cannot hand a derived day to another.
        let generations = LooprSharedGenerationCache()
        var now: Date { Date(timeIntervalSince1970: Double(dayStart + 36_000)) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
            productsURL = root.appendingPathComponent("products.sqlite")
            try seedNight(seconds: 14_401)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        func engine(clock: DateProviding, budget: LooprDerivationBudget,
                    namespace: String = "daily-analytics",
                    sharedGenerations: LooprSharedGenerationCache? = nil) throws -> CanonicalDailyAnalytics {
            try CanonicalDailyAnalytics(
                history: history, products: try StorageDatabase(url: productsURL),
                profile: InMemoryProfileRepository(),
                dateProvider: clock,
                timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!),
                namespace: namespace,
                budget: budget,
                sharedGenerations: sharedGenerations ?? self.generations
            )
        }

        func seedNight(seconds: Int, heartRate: Int = 55) throws {
            try history.write { db in
                for index in 0..<seconds {
                    let timestamp = dayStart + Int64(index)
                    try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-07', 24, ?, 0, 0, 1)", arguments: [timestamp, index, timestamp, heartRate])
                    let id = db.lastInsertedRowID
                    let interval = Int((1_000 + 80 * sin(2 * .pi * 0.25 * Double(index))).rounded())
                    try db.execute(sql: "INSERT INTO rr_beat(decoded_second_id, beat_index, rr_milliseconds, beat_timestamp_milliseconds) VALUES (?, 0, ?, ?)", arguments: [id, interval, timestamp * 1_000])
                }
            }
        }

        func appendSecond(at timestamp: Int64) throws {
            try history.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2026-09-07', 24, 60, 0, 0, 1)", arguments: [timestamp, 99_999, timestamp])
            }
        }
    }
}
