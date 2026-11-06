import DataKit
import DesignSystem
import Foundation
import Testing
@testable import Loopr

/// LV-08b step 3: every number the app shows has a method page, and Data's stack opens it.
@MainActor
struct MethodRouteTests {
    /// Walks the metric list: a metric without a method page fails here.
    @Test(arguments: MetricKey.allCases)
    func everyMetricHasAMethodPage(_ key: MetricKey) throws {
        let id = try #require(MethodMetricText.methodID(for: key), "\(key.rawValue) has no method page")
        #expect(MethodCatalog.entry(id).metricKeys.contains(key.rawValue))
    }

    @Test func everyClaimedMetricKeyIsARealMetric() {
        for key in MethodCatalog.entries.flatMap(\.metricKeys) {
            #expect(MetricKey(rawValue: key) != nil, "\(key) is not a MetricKey")
        }
    }

    @Test func metricPagesReuseTheMetricCatalogText() throws {
        let content = try #require(MethodMetricText.content(for: MethodCatalog.entry(.recovery)))
        #expect(content.calculation == MetricContentCatalog.content(for: .recovery).calculation)
        #expect(MethodMetricText.content(for: MethodCatalog.entry(.phenoAge)) == nil)
    }

    @Test func debugLaunchArgumentOpensAMethodOnDataStack() {
        #expect(MethodLaunchArgument.healthPath(["--loopr-method=phenoage"]) == [.methods, .method(.phenoAge)])
        #expect(MethodLaunchArgument.healthPath(["--loopr-method=recovery"]) == [.methods, .method(.recovery)])
        #expect(MethodLaunchArgument.healthPath(["--loopr-method=list"]) == [.methods])
        #expect(MethodLaunchArgument.healthPath(["--loopr-method=not-a-method"]) == nil)
        #expect(MethodLaunchArgument.healthPath(["--loopr-method-fixture"]) == nil)
        #expect(MethodLaunchArgument.usesFixtureValues(["--loopr-method-fixture"]))
    }

    @Test func fixtureValuesExistForThePagesWithAWaterfall() throws {
        let phenoAge = try #require(MethodFixtures.value(for: .phenoAge))
        let waterfall = try #require(phenoAge.waterfall)
        #expect(abs(waterfall.model.end - phenoAge.value) < 1e-9)
        #expect(MethodFixtures.value(for: .recovery)?.waterfall != nil)
        #expect(MethodFixtures.value(for: .steps) == nil)
    }
}
