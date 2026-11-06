import XCTest
import AnalyticsKit
import DataKit
import DesignSystem
import FoodKit
import Foundation
import RoutineKit
import StorageKit
@testable import Loopr

/// A history that returns fixed points, so the loader runs without the band or Apple Health.
private nonisolated struct StubHistory: MetricHistoryProviding {
    var points: [MetricKey: [MetricHistoryPoint]]
    func series(for key: MetricKey, days: Int, endingOn: Date) async throws -> [MetricHistoryPoint] { points[key] ?? [] }
}

final class PublishDataLoaderTests: XCTestCase {
    private var roots: [URL] = []
    private let zone = TimeZone(identifier: "UTC")!
    /// 25 October 2026, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_929_600)

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private func database() throws -> StorageDatabase {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PublishDataLoaderTests-\(UUID().uuidString)")
        roots.append(root)
        return try StorageDatabase(url: root.appendingPathComponent("products.sqlite"), applicationVersion: "publish-loader-tests")
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
    }

    private func loader(history: [MetricKey: [MetricHistoryPoint]] = [:], database: StorageDatabase? = nil) -> PublishDataLoader {
        let captured = now
        return PublishDataLoader(history: StubHistory(points: history), database: database, timeZone: zone, now: { captured })
    }

    private func decimal(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    func testEveryMetricKeyIsListedAndOnlyOnesWithDataCanBePicked() async throws {
        let points = [MetricHistoryPoint(day: day(1), value: 54, source: .band)]
        let found = await loader(history: [.rmssd: points]).candidates()
        for key in MetricKey.allCases { XCTAssertTrue(found.contains { $0.key == key.rawValue }, key.rawValue) }
        let withData = found.filter(\.hasData).map(\.key)
        XCTAssertEqual(withData, ["rmssd"])
        let hrv = try XCTUnwrap(found.first { $0.key == "rmssd" })
        XCTAssertEqual(hrv.name, "HRV")
        XCTAssertEqual(hrv.unit, "ms")
        XCTAssertEqual(hrv.group, .heart)
        XCTAssertTrue(found.contains { $0.key == "food_energy" && !$0.hasData })
        XCTAssertTrue(found.contains { $0.key == "protocol_rules_kept" && !$0.hasData })
        XCTAssertFalse(found.contains { $0.group == .bloodTests }, "no blood test is listed before one is stored")
    }

    func testEveryMetricKeyHasAGroupThatTheDashboardShows() {
        for key in MetricKey.allCases {
            XCTAssertTrue([PublishGroup.sleep, .heart, .fitness].contains(PublishDataLoader.group(for: key)), key.rawValue)
        }
    }

    func testAMetricSeriesCarriesDaysUnitAndSources() async throws {
        let points = [
            MetricHistoryPoint(day: day(3), value: 56, source: .band),
            MetricHistoryPoint(day: day(1), value: 54, source: .appleHealth)
        ]
        let found = await loader(history: [.restingHeartRate: points]).series(keys: ["resting_heart_rate"], period: .days30)
        let series = try XCTUnwrap(found.first)
        XCTAssertEqual(series.name, "Resting heart rate")
        XCTAssertEqual(series.unit, "bpm")
        XCTAssertEqual(series.source, "Apple Health, WHOOP band")
        XCTAssertEqual(series.values, [PublishDayValue(date: "2026-10-22", value: 56), PublishDayValue(date: "2026-10-24", value: 54)])
    }

    func testAnUnknownKeyReturnsNothing() async {
        let found = await loader().series(keys: ["not_a_metric", "lab_nothing"], period: .days30)
        XCTAssertTrue(found.isEmpty)
    }

    func testBloodTestsComeFromReportDaysInTheUnitOfTheLatestReport() async throws {
        let database = try database()
        let store = LabStore(database: database)
        func report(_ offset: Int) -> LabReport {
            LabReport(collectedAt: day(offset).addingTimeInterval(8 * 3_600), timeZoneIdentifier: "UTC", labName: "Lab",
                      fasting: true, source: .typed, createdAt: day(offset))
        }
        let early = report(40), older = report(20), latest = report(5)
        try store.saveReport(early, values: [LabValue(reportID: early.id, subject: .marker(.apoB), value: decimal("0.9"), unit: "g/L", source: .typed)])
        try store.saveReport(older, values: [LabValue(reportID: older.id, subject: .marker(.apoB), value: decimal("88"), unit: "mg/dL", source: .typed)])
        try store.saveReport(latest, values: [
            LabValue(reportID: latest.id, subject: .marker(.apoB), value: decimal("80.5"), unit: "mg/dL", source: .typed),
            LabValue(reportID: latest.id, subject: .other(name: "Selenium"), value: decimal("1.2"), unit: nil, source: .typed)
        ])
        let subject = loader(database: database)

        let found = await subject.candidates()
        let blood = found.filter { $0.group == .bloodTests }
        XCTAssertEqual(Set(blood.map(\.name)), ["Apolipoprotein B", "Selenium"])
        XCTAssertTrue(blood.allSatisfy(\.hasData))

        let series = await subject.series(keys: blood.map(\.key), period: .months12)
        let apob = try XCTUnwrap(series.first { $0.name == "Apolipoprotein B" })
        XCTAssertEqual(apob.unit, "mg/dL")
        XCTAssertEqual(apob.source, "Blood test reports")
        // The 0.9 g/L value from the oldest report is another unit, so it stays out.
        XCTAssertEqual(apob.values, [PublishDayValue(date: "2026-10-05", value: 88), PublishDayValue(date: "2026-10-20", value: 80.5)])
        let selenium = try XCTUnwrap(series.first { $0.name == "Selenium" })
        XCTAssertEqual(selenium.unit, "")
        XCTAssertEqual(selenium.values, [PublishDayValue(date: "2026-10-20", value: 1.2)])
    }

    func testFoodDaysCountOnlyWhenEveryItemReportsTheNutrient() async throws {
        let database = try database()
        let store = FoodStore(database: database)
        func item(_ name: String, _ nutrients: [FoodNutrient: Double], at date: Date) -> FoodItem {
            FoodItem(name: name, amount: 1, unit: .serving, nutrients: .init(nutrients), provenance: [.init(source: .typed, recordedAt: date)])
        }
        let whole = day(2).addingTimeInterval(12 * 3_600)
        _ = try store.confirm(.init(slot: .lunch, occurredAt: whole, timeZoneIdentifier: "UTC",
                                    items: [item("Rice", [.energy: 500, .protein: 12], at: whole), item("Beans", [.energy: 200, .protein: 14], at: whole)]), at: whole)
        let partial = day(1).addingTimeInterval(12 * 3_600)
        _ = try store.confirm(.init(slot: .lunch, occurredAt: partial, timeZoneIdentifier: "UTC",
                                    items: [item("Soup", [.energy: 300], at: partial), item("Bread", [:], at: partial)]), at: partial)
        let subject = loader(database: database)

        let found = await subject.candidates()
        XCTAssertTrue(found.first { $0.key == "food_energy" }?.hasData == true)
        XCTAssertTrue(found.first { $0.key == "food_protein" }?.hasData == true)
        XCTAssertTrue(found.first { $0.key == "food_fibre" }?.hasData == false)

        let series = await subject.series(keys: ["food_energy", "food_protein"], period: .days30)
        XCTAssertEqual(series.first { $0.key == "food_energy" }?.values, [PublishDayValue(date: "2026-10-23", value: 700)])
        XCTAssertEqual(series.first { $0.key == "food_protein" }?.values, [PublishDayValue(date: "2026-10-23", value: 26)])
        XCTAssertEqual(series.first { $0.key == "food_energy" }?.source, "Loopr food log")
    }

    /// ICP R3-UPG-7: in the populated launch the report file greyed out Calories, Protein, Fibre and "Protocol rules
    /// kept" while Food and Protocol showed data, because it read the products database and the tabs read their own
    /// fixture stores. Handed the stores the tabs read, it finds the same data.
    func testTheReportFileReadsTheStoresTheFoodAndProtocolTabsRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PublishFixtureStores-\(UUID().uuidString)")
        roots.append(root)
        let routine = try ProtocolTabFixture.makeStores(in: root, now: now, timeZone: zone).routine
        let food = FoodStore(database: try database())
        try AppFoodFixtures.seed(food, endingOn: now)
        let captured = now
        let subject = PublishDataLoader(history: StubHistory(points: [:]), stores: { PublishStores(food: food, routine: routine) },
                                        timeZone: zone, now: { captured })
        let found = await subject.candidates()
        XCTAssertTrue(found.first { $0.key == "food_energy" }?.hasData == true)
        XCTAssertTrue(found.first { $0.key == PublishDataLoader.protocolKey }?.hasData == true)
        let kept = await subject.series(keys: [PublishDataLoader.protocolKey], period: .days30)
        XCTAssertFalse(kept.first?.values.isEmpty ?? true)
    }

    func testAnEmptyDatabaseListsNoBloodTestAndNoFoodData() async throws {
        let found = await loader(database: try database()).candidates()
        XCTAssertFalse(found.contains { $0.hasData })
        XCTAssertFalse(found.contains { $0.group == .bloodTests })
    }

    /// ICP R1-LAB-24: the page a person may hand to a doctor uses plain names and units.
    func testThePageUsesPlainNamesAndUnits() {
        XCTAssertEqual(PublishDataLoader.name(for: .vo2Max), "VO₂max")
        XCTAssertEqual(PublishDataLoader.name(for: .sleepPerformance), "Hours slept against need")
        XCTAssertEqual(PublishDataLoader.name(for: .sdnn), "SDNN")
        XCTAssertEqual(PublishDataLoader.unit(for: .respiratoryRate), "breaths per minute")
        // An all-caps acronym keeps its capitals on screen.
        XCTAssertEqual("SDNN".looprLabelCased, "SDNN")
    }
}
