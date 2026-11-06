import AnalyticsKit
import DataKit
import DesignSystem
import Foundation
import HealthKitBridge
import SettingsKit
import StorageKit
import Testing
@testable import Loopr

/// LV-08b integration: every Data root action opens the right screen. A pin opens its real method page with its value,
/// the vault opens Publish a page, the sources row and an Explore row open the blood tests, another Explore row opens
/// "How the numbers work", a metric page links to its method page, and Lab mode's saved confirmation opens the saved
/// report.
@MainActor
struct DataIntegrationTests {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// 25 October 2026, 12:00 in Berlin.
    private var now: Date { berlin.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))! }

    /// The Data fixture's ruler: Alex, 38, two blood tests and three Apple Watch VO₂max readings.
    private func fixtureRuler() -> DataAgeRuler {
        let calendar = berlin
        return DataAgeRuler.make(birthYear: calendar.component(.year, from: now) - 38,
                                 draws: DataOverviewFixtures.labDraws(now: now),
                                 vo2Max: DataOverviewMapping.vo2Max(DataOverviewFixtures.appleHealth(.vo2Max, now: now, calendar: calendar)),
                                 referenceGroup: .male, now: now, calendar: calendar)
    }

    // MARK: Pins

    @Test func theBloodPinOpensThePhenoAgePageWithItsValueAndWaterfall() throws {
        let ruler = fixtureRuler()
        let pin = try #require(ruler.state(.blood).pin)
        guard case .method(let id, let value?) = ruler.opening(for: .blood) else {
            Issue.record("the blood pin did not open a method page with a value")
            return
        }
        #expect(id == .phenoAge)
        #expect(abs(value.value - pin.years) < 1e-9)
        let waterfall = try #require(value.waterfall)
        #expect(abs(waterfall.model.end - pin.years) < 1e-9)
        #expect(MethodCatalog.entry(id).title == "Blood age")
    }

    @Test func theCardioPinOpensTheCardioAgePageWithItsValue() throws {
        let ruler = fixtureRuler()
        let pin = try #require(ruler.state(.cardio).pin)
        guard case .method(let id, let value?) = ruler.opening(for: .cardio) else {
            Issue.record("the cardio pin did not open a method page with a value")
            return
        }
        #expect(id == .cardioAge)
        #expect(abs(value.value - pin.years) < 1e-9)
    }

    @Test func realAgeOpensProfileAndAbsentPinsOpenWhereTheirInputIsAdded() {
        #expect(fixtureRuler().opening(for: .real) == .profile)
        let empty = DataAgeRuler.make(birthYear: nil, draws: [], vo2Max: .readings([]), referenceGroup: nil,
                                      now: now, calendar: berlin)
        // No blood test yet: the blood tests list, where one is added.
        #expect(empty.opening(for: .blood) == .bloodTests)
        // No VO₂max readings yet: how to get them.
        #expect(empty.opening(for: .cardio) == .vo2MaxGuide)
        #expect(empty.opening(for: .real) == .profile)
    }

    @Test func aPinPushesOnTheRootsOwnStackAndTheLockedTileKeepsItsPlan() {
        #expect(DataTabDestination.pin(.blood).id != DataTabDestination.pin(.cardio).id)
        #expect(DataTabDestination.pin(.blood) != .looprAgePlan)
        // The Loopr age method page has no stage list, so the plan page stays.
        #expect(MethodCatalog.entry(.looprAge).rule.joined().contains("docs/LOOPR_AGE.md"))
        #expect(DataLooprAgePlan.stages.count == 4)
    }

    // MARK: Vault, sources and Explore

    @Test func theVaultOpensPublishAPage() {
        #expect(DataRootRouting.publish == .publish)
    }

    @Test func theSourcesRowsOpenTheirScreensAndLabsOpensTheBloodTests() {
        #expect(DataRootRouting.source(.labs) == .labs)
        #expect(DataRootRouting.source(.band) == .settingsFlow(.settings(.deviceCenter)))
        #expect(DataRootRouting.source(.appleHealth) == .settingsFlow(.settings(.healthKit)))
        #expect(DataRootRouting.source(.whoopExport) == .settingsFlow(.data(.importPreview)))
    }

    @Test func theExploreRowsOpenTheBloodTestsAndHowTheNumbersWork() {
        #expect(DataRootRouting.bloodTests == .labs)
        #expect(DataRootRouting.methods == .methods)
        #expect(DataRootRouting.bloodTests != DataRootRouting.methods)
    }

    // MARK: Metric detail

    @Test(arguments: MetricKey.allCases)
    func everyMetricPageLinksToItsMethodPage(_ key: MetricKey) throws {
        let id = try #require(MetricDetailMethodLink.methodID(for: key), "\(key.rawValue) has no method page link")
        #expect(id == MethodCatalog.entry(forMetricKey: key.rawValue)?.id)
        #expect(MethodCatalog.entry(id).metricKeys.contains(key.rawValue))
    }

    @Test func theMethodLinkReadsPlainlyAndKeepsItsIdentifier() {
        #expect(MetricDetailMethodLink.title == "How this is worked out")
        #expect(MetricDetailMethodLink.identifier == "metric-detail-method-link")
        for text in [MetricDetailMethodLink.title, MetricDetailMethodLink.hint] {
            #expect(!text.contains("!"))
            #expect(!text.contains("\u{2014}"))
        }
    }

    // MARK: Lab mode

    @Test func theSavedReportOpensOnTheBloodTestsListWithTheReportOnTop() {
        let id = UUID()
        #expect(LabReportLink.path(for: id) == [.labs, .labReport(id)])
    }

    @Test func labModeKeepsTheSavedReportIDUntilTheNextRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DataIntegrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try StorageDatabase(url: root.appendingPathComponent("labs.sqlite"), applicationVersion: "data-integration-tests")
        let store = LabStore(database: database)
        let perth = TimeZone(identifier: "Australia/Perth")!
        let lab = FoodLabModel(timeZone: perth, reader: FoodLabFixture.reader(.english), minimumReading: .zero)
        #expect(lab.savedReportID == nil)
        await lab.read(try FoodCaptureFixtures.photo(at: Date(timeIntervalSince1970: 1_700_000_000)))
        await lab.save(to: store)
        #expect(lab.stage == .saved)
        let stored = try #require(try store.reports().first)
        #expect(lab.savedReportID == stored.id)
        lab.reset()
        #expect(lab.savedReportID == nil)
    }
}
