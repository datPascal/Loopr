import AnalyticsKit
import DesignSystem
import Foundation
import StorageKit
import SwiftUI
import Testing
@testable import Loopr

struct ArchivedVitalsPresentationTests {
    @Test @MainActor
    func catalogLinksOpenImportedReadingsWithoutEnablingBandOxygen() {
        var opened: MetricDetailRoute?
        let link = MetricDetailNavigation.link(
            provider: FixtureMetricHistoryProvider(),
            route: Binding(get: { opened }, set: { opened = $0 })
        )
        for key in MetricKey.allCases {
            #expect(link.supports(key.rawValue))
            link.open(key.rawValue)
            #expect(opened?.key == key)
        }
        #expect(!link.supports("unknown-metric"))
        #expect(MetricKey.oxygenSaturation.presentation.availability == .importedOnly)
        #expect(MetricKey.oxygenSaturation.historySourcePreference == [.whoopExport, .appleHealth])
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
