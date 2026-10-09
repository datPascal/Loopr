import XCTest
import Foundation
import SwiftUI
import UIKit
import ImportKit
import StorageKit
import DomainKit
import ProfileKit
import TodayKit
import SleepKit
import DesignSystem
import WorkoutKit
@testable import Loopr

nonisolated private struct ImportTestDate: DateProviding {
    let value: Date
    func now() -> Date { value }
}

@MainActor
final class WHOOPImportIntegrationTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []
        super.tearDown()
    }
    private func setup() throws -> (StorageDatabase, StorageDatabase, WHOOPImportStore, CanonicalDailyAnalytics) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-app-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); roots.append(root)
        let history = try StorageDatabase(url: root.appendingPathComponent("history.sqlite"))
        let products = try StorageDatabase(url: root.appendingPathComponent("products.sqlite"))
        let store = try WHOOPImportStore(database: history)
        let header = "Cycle start time,Cycle timezone,Wake onset,Sleep onset,Asleep duration (min),Deep (SWS) duration (min),REM duration (min),Light sleep duration (min),Awake duration (min),Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Day Strain,Sleep need (min)\n"
        var csv = header
        for day in 1...30 {
            let label = String(format: "2021-04-%02d", day)
            csv += "\(label) 00:15:00,UTC+08:00,\(label) 08:00:00,\(label) 00:15:00,420,90,85,245,45,81,52,62,11.4,465\n"
        }
        csv += "2017-03-02 00:00:00,UTC+08:00,2017-03-02 07:00:00,2017-03-02 00:00:00,395,85,80,230,25,75,54,56,8.7,460\n"
        let url = root.appendingPathComponent("physiological_cycles.csv"); try Data(csv.utf8).write(to: url)
        _ = try store.apply(csvs: [url])
        let engine = try CanonicalDailyAnalytics(history: history, products: products, profile: InMemoryProfileRepository(),
            dateProvider: SystemDateProvider(), timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!),
            budget: LooprDerivationBudget(foreground: LooprFixedForegroundState(true)), sharedGenerations: LooprSharedGenerationCache())
        return (history, products, store, engine)
    }
    func testImportedDaysReachTodaySleepDaySelectionAndMetricHistoryWithoutDerivingRaw() async throws {
        let (history, products, _, engine) = try setup()
        let day = DayIdentity(year: 2021, month: 4, day: 30)
        let todayRepo = try SQLiteTodayRepository(database: products, analytics: engine)
        let sleepRepo = try SQLiteSleepRepository(database: products, analytics: engine)
        let today = try await todayRepo.readSummary(for: day)
        let sleep = try await sleepRepo.readSleepDay(for: day)
        XCTAssertEqual(today?.metric(.recovery)?.numericValue, 81)
        XCTAssertEqual(today?.metric(.recovery)?.source, "Account export")
        XCTAssertEqual(sleep?.trend.count, 30); XCTAssertTrue(sleep?.hypnogram.isEmpty == true)
        XCTAssertEqual(sleep?.mainSleep?.durationMinutes, 420)
        XCTAssertEqual(sleep?.mainSleep?.isPartial, false)
        XCTAssertTrue(sleep?.trend.allSatisfy { $0.value == 7 && $0.unit == "h" } == true)
        let insights = SleepNightInsights(snapshot: try XCTUnwrap(sleep))
        XCTAssertEqual(insights.durationUsual.range?.median, 420)
        let knowledge = try await engine.dayKnowledge(today: DayIdentity(year: 2026, month: 10, day: 6))
        XCTAssertTrue(knowledge.withData.contains(day))
        XCTAssertEqual(knowledge.earliestDay, DayIdentity(year: 2017, month: 3, day: 2))
        let derivations = await engine.derivationCount; XCTAssertEqual(derivations, 0)
        let provider = LooprMetricHistory()
        provider.attach(history: history, analytics: engine, timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!),
            dateProvider: SystemDateProvider(), healthClient: nil, scheduleWork: false)
        let end = ISO8601DateFormatter().date(from: "2021-04-30T23:59:59Z")!
        let points = try await provider.series(for: .sleepDuration, days: 31, endingOn: end)
        XCTAssertEqual(points.count, 30); XCTAssertEqual(points.first?.value, 420)
        XCTAssertEqual(points.first?.source, .whoopExport)
        try history.upsertMetricSeries([.init(localDay: "2021-04-30", metricKey: "sleep_duration", source: .band, value: 410)], updatedAt: 1)
        let resolved = try await provider.series(for: .sleepDuration, days: 31, endingOn: end)
        XCTAssertEqual(resolved.last?.value, 410); XCTAssertEqual(resolved.last?.source, .band)
    }
    func testBandDayProjectionSuppressesImportedDay() async throws {
        let (history, _, _, engine) = try setup()
        let timestamp: Int64 = 1_619_786_400 // 2021-04-30 12:40 UTC.
        try history.write { db in
            for index in 0..<120 {
                try db.execute(sql: "INSERT INTO decoded_second(physiological_timestamp, band_counter, absolute_timestamp, local_day, record_version, heart_rate, gravity_x, gravity_y, gravity_z) VALUES (?, ?, ?, '2021-04-30', 24, 70, 0, 0, 1)", arguments: [timestamp + Int64(index), index, timestamp + Int64(index)])
            }
        }
        let display = try await engine.readDisplay(day: DayIdentity(year: 2021, month: 4, day: 30))
        let value = try XCTUnwrap(display)
        XCTAssertNotEqual(value.projection.algorithmVersion, "account-export-v1")
        XCTAssertNotEqual(value.today.metric(.strain)?.source, "Account export")
    }
    func testNativeWorkoutRepositoryResolvesImportedSessionsAndSourceTotals() async throws {
        let (_, products, imports, _) = try setup()
        let root = roots[0]
        let url = root.appendingPathComponent("workouts.csv")
        try Data("Workout start time,Workout end time,Cycle timezone,Activity name,Activity Strain,Average HR (bpm)\n2021-04-30 10:00:00,2021-04-30 10:40:00,UTC,Running,6.5,138".utf8).write(to: url)
        _ = try imports.apply(csvs: [url])
        let repository = try SQLiteWorkoutStore(database: products, accountImport: imports)
        let all = await repository.all(); let imported = try XCTUnwrap(all.first)
        XCTAssertEqual(imported.importedSummary?.averageHeartRate, 138)
        let listing = await repository.listingRows(WorkoutLogQuery(range: .all, now: Date()))
        XCTAssertEqual(listing.count, 1)
        var native = imported; native.source = .detected; native.importedSummary = nil
        try await repository.save(native)
        let merged = await repository.all(); XCTAssertEqual(merged, [native])
    }
    func testTodaySleepAndTrendsRenderImportedHistoryInLightDarkAndLargeType() async throws {
        let motion = "reduced-motion"
        let originalAppearance = DesignSystemRuntime.state()
        defer { DesignSystemRuntime.apply(originalAppearance) }
        let (history, products, _, engine) = try setup()
        let day = DayIdentity(year: 2021, month: 4, day: 30)
        let provider = LooprMetricHistory()
        provider.attach(history: history, analytics: engine, timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!),
            dateProvider: SystemDateProvider(), healthClient: nil, scheduleWork: false)
        let sleepRepository = try SQLiteSleepRepository(database: products, analytics: engine)
        let contextRepository = LooprTodayContextSource(history: provider, timeZone: TimeZone(secondsFromGMT: 0)!,
            sleepDay: { @Sendable [sleepRepository] day in try? await sleepRepository.readSleepDay(for: day) },
            bodyDay: { @Sendable _ in nil }, journalEntries: { @Sendable _ in [] }, alarmMinute: { @Sendable in nil })
        let todayModel = TodayViewModel(repository: try SQLiteTodayRepository(database: products, analytics: engine),
            contextRepository: contextRepository)
        let sleepModel = SleepViewModel(repository: sleepRepository)
        await todayModel.load(day: day); await sleepModel.load(day: day)
        let dashboard = try XCTUnwrap(todayModel.dashboard(isToday: false))
        XCTAssertEqual(dashboard.hero.reading?.score, 81)
        XCTAssertEqual(dashboard.hero.reading?.driver, "From your account export")
        XCTAssertNil(todayModel.context?.recovery?.score, "Constant imported heart readings cannot produce a Loopr score")
        XCTAssertEqual(dashboard.morningSignalsSubtitle, "Usual ranges need 14 nights with a reading.")
        XCTAssertNil(dashboard.contributors.first(where: { $0.id == LooprMetricLinkID.rmssd })?.learning)
        XCTAssertNil(dashboard.contributors.first(where: { $0.id == LooprMetricLinkID.restingHeartRate })?.learning)
        let knowledge = try await engine.dayKnowledge(today: day)
        let currentDay = DayIdentity(year: 2026, month: 10, day: 6)
        let selection = LooprDaySelection(today: currentDay, dateProvider: ImportTestDate(value: ISO8601DateFormatter().date(from: "2026-10-06T12:00:00Z")!), timeZoneProvider: SystemTimeZoneProvider(timeZone: TimeZone(secondsFromGMT: 0)!), knowledge: knowledge)
        selection.select(day)
        let anchor = MetricDetailAnchor(selectedDay: LooprDays.looprDay(day), today: LooprDays.looprDay(currentDay))
        let model = MetricDetailModel(key: .sleepDuration, anchor: anchor)
        await model.load(from: provider, anchor: anchor)
        XCTAssertEqual(model.points.count, 30)
        for dark in [false, true] {
            DesignSystemRuntime.apply(.init(appearance: dark ? .dark : .light, reduceMotion: true))
            for large in [false, true] {
                let suffix = "\(dark ? "dark" : "light")-\(large ? "large" : "regular")"
                let screens: [(String, AnyView)] = [
                    ("today", AnyView(TodayScreen(viewModel: todayModel))),
                    ("sleep", AnyView(SleepScreen(viewModel: sleepModel))),
                    ("trends", AnyView(MetricDetailScreen(key: .sleepDuration, model: model)
                        .environment(\.metricHistoryProvider, provider)
                        .environment(\.looprDaySelection, selection)))
                ]
                for (name, view) in screens {
                    let host = UIHostingController(rootView: view.environment(\.looprDayNavigation, selection.navigation)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.dynamicTypeSize, large ? .accessibility5 : .large)
                        .transaction { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        })
                    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                    let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
                    window.overrideUserInterfaceStyle = dark ? .dark : .light
                    window.rootViewController = host; window.makeKeyAndVisible()
                    host.view.frame = window.bounds; host.view.layoutIfNeeded()
                    let expectation = expectation(description: "Layout \(name)")
                    DispatchQueue.main.async { expectation.fulfill() }
                    await fulfillment(of: [expectation], timeout: 10)
                    host.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                        XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
                    }
                    XCTAssertEqual(image.size.width, 402)
                    let attachment: XCTAttachment = XCTAttachment(image: image); attachment.name = "import-\(name)-\(suffix)-\(motion)"
                    attachment.lifetime = .keepAlways; add(attachment)
                    window.isHidden = true
                    previousKeyWindow?.makeKey()
                }
            }
        }
    }

    func testLoadedMetricModelCanBeReleasedAwayFromTheMainActor() async {
        for key in [MetricKey.sleepDuration, .skinTemperatureDeviation] {
            var model: MetricDetailModel? = MetricDetailModel(key: key)
            await model?.load(from: FixtureMetricHistoryProvider(), anchor: MetricDetailAnchor(day: Date(), today: Date()))
            weak var released = model
            var task: Task<Void, Never>? = Task.detached { @Sendable [model] in
                _ = await model?.latest
            }
            model = nil
            await task?.value
            task = nil
            XCTAssertNil(released, "A finished metric page must release its model: \(key)")
        }
    }
}
