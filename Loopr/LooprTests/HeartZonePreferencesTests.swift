import DomainKit
import XCTest
@testable import Loopr

final class HeartZonePreferencesTests: XCTestCase {
    func testProfileAgeChangeInvalidatesTheZoneRevision() async {
        let name = "HeartZonePreferencesTests.age.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HeartZonePreferences(defaults: defaults)

        await preferences.profileAgeChanged()

        XCTAssertEqual(defaults.integer(forKey: HeartZonePreferences.revisionKey), 1)
    }

    func testSavedZoneSettingsSurviveAStoreRecreationAndAdvanceRevision() async throws {
        let suite = "com.loopr.tests.heart-zones.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = HeartZonePreferences(defaults: defaults)
        let initial = await first.load()
        XCTAssertEqual(initial, HeartRateZoneSettings())
        let changed = HeartRateZoneSettings(manualMaximum: 176, innerBoundaries: [55, 65, 75, 85])
        await first.save(changed)
        XCTAssertEqual(defaults.integer(forKey: HeartZonePreferences.revisionKey), 1)
        let restored = HeartZonePreferences(defaults: defaults)
        let reloaded = await restored.load()
        XCTAssertEqual(reloaded, changed)
        await restored.save(changed)
        XCTAssertEqual(defaults.integer(forKey: HeartZonePreferences.revisionKey), 1)
    }
}
