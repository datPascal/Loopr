import AnalyticsKit
import DesignSystem
import Foundation
import SwiftUI
import Testing
@testable import Loopr

struct ArchivedVitalsPresentationTests {
    @Test @MainActor
    func metricLinksDoNotOpenArchivedVitals() {
        let link = MetricDetailNavigation.link(
            provider: FixtureMetricHistoryProvider(),
            route: Binding<MetricDetailRoute?>.constant(nil)
        )
        #expect(!link.supports(LooprMetricLinkID.oxygenSaturation))
        #expect(link.supports(LooprMetricLinkID.skinTemperatureDeviation))
        #expect(link.supports(LooprMetricLinkID.stress))
    }

    @Test
    func overnightCheckUsesOnlySupportedReadings() async {
        let source = MetricHistoryOvernightSource(provider: FixtureMetricHistoryProvider(), fallback: nil)
        let nights = await source.nights(endingOn: Date(), days: 30, calendar: .current)
        #expect(!nights.isEmpty)
        #expect(nights.allSatisfy { night in
            night.values.keys.allSatisfy {
                $0 == .restingHeartRate || $0 == .heartRateVariability || $0 == .respiratoryRate
            }
        })
    }
}
