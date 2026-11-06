import AnalyticsKit
import DataKit
import Foundation
import SettingsKit

/// Where each tap on the Data root goes (LV-08b integration). The root reads this table, so the routes it opens and
/// the routes its tests expect come from one place.
///
/// Two ways in need no table: an Explore row names its route where it is drawn, and a pin opens through
/// `DataAgeRuler.opening(for:)`, which carries the pin's value.
enum DataRootRouting {
    /// The vault's "Publish a page".
    static let publish = AppHealthRoute.publish
    /// The Explore row "Blood tests" (`health-explore-labs`).
    static let bloodTests = AppHealthRoute.labs
    /// The Explore row "How the numbers work" (`health-explore-methods`).
    static let methods = AppHealthRoute.methods

    /// What a year row opens: a band metric's page, a lab marker's history ("lab-apob"), or the blood tests.
    static func slope(_ id: String) -> AppHealthRoute {
        if let key = MetricKey(rawValue: id) { return .metric(key) }
        if id.hasPrefix("lab-"), let marker = LabMarkerKey(rawValue: String(id.dropFirst(4))) { return .labMarker(marker) }
        return bloodTests
    }

    /// What a row of the vault's sources opens. The labs row opens the blood tests.
    static func source(_ kind: DataSourceKind) -> AppHealthRoute {
        switch kind {
        case .band: .settingsFlow(.settings(.deviceCenter))
        case .appleHealth: .settingsFlow(.settings(.healthKit))
        case .whoopExport: .settingsFlow(.data(.importPreview))
        case .labs: bloodTests
        }
    }
}
