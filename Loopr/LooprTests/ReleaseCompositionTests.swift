import BluetoothKit
import Foundation
import ProtocolKit
import SettingsKit
import Testing

@testable import Loopr

struct ReleaseCompositionTests {
    @Test
    func productionManifestEnablesLiveActivities() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true)
    }

    @Test
    @MainActor
    func productionCompositionKeepsFixtureResearchAndDiagnosticsSurfacesClosed() async throws {
        let production = AppEnvironment.production()
        #expect(production.composition == .production)
        #expect(production.storageURL != nil)
        #expect(!AccessoryDescriptorCatalog.descriptors(for: .appStore).contains {
            $0.generation == .gen5
        })
        #expect(!HiddenDiagnosticsGate(releaseBuild: true).canOpen(route: .hiddenDiagnostics))
        let gen5 = Gen5FeatureGate(store: InMemoryGen5KillSwitchStore())
        #expect(!(await gen5.isEnabled()))

        #if !DEBUG
        for mode in LaunchMode.allCases {
            #expect(AppEnvironment.make(
                arguments: ["app", "--loopr-launch-mode=\(mode.rawValue)"],
                environment: [LaunchModeParser.environmentKey: mode.rawValue]
            ).composition == .production)
        }
        #endif
    }
}
