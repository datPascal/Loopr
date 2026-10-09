import AnalyticsKit
import Foundation
import WorkoutKit
import DomainKit
import XCTest

final class WorkoutZoneAlertTests: XCTestCase {
    func testZoneTwoTargetMatchesReserveZoneAndManualStaysTargetOnly() {
        let shared = HeartRateZoneSettings(manualMaximum: 184).resolved(age: nil, restingNights: [51])!
        let zones = ActivityAnalytics.zones(shared, source: .manual).value!
        let preset = ZoneTwoRange.resolve(zones: shared)!
        XCTAssertEqual(WorkoutZoneAlertTarget.zone(2).range(in: zones), preset.range)
        var preference = WorkoutZoneAlertPreference(target: .zoneTwo)
        let target = WorkoutZoneTarget(preference: preference, zones: zones, zoneTwo: preset)!
        XCTAssertEqual(target.range, 131...144)
        preference.manualZoneTwo = .init(lower: 140, upper: 150, source: .manual)
        XCTAssertEqual(WorkoutZoneTarget(preference: preference, zones: zones, zoneTwo: preset)?.range, 140...150)
        XCTAssertEqual(WorkoutZoneAlertTarget.zone(2).range(in: zones), 131...144)
    }

    private let start = Date(timeIntervalSince1970: 1000)
    private func observe(_ machine: inout WorkoutZoneAlertMachine, _ bpm: Int?, _ seconds: Double,
                         elapsed: Double = .infinity, preference: WorkoutZoneAlertPreference = .init()) -> WorkoutZoneAlertEvent? {
        machine.observe(bpm: bpm, at: start.addingTimeInterval(seconds), target: 130...150,
                        activeElapsed: elapsed, preference: preference)
    }
    func testWarmUpStartsDwellOnlyAfterGrace() {
        var machine = WorkoutZoneAlertMachine()
        XCTAssertNil(observe(&machine, 160, 0, elapsed: 0))
        XCTAssertNil(observe(&machine, 160, 479, elapsed: 479))
        XCTAssertNil(observe(&machine, 160, 480, elapsed: 480))
        XCTAssertNil(observe(&machine, 160, 509, elapsed: 509))
        XCTAssertEqual(observe(&machine, 160, 510, elapsed: 510), .tooHigh)
    }
    func testHighOnlyDefaultAndLowSwitch() {
        var machine = WorkoutZoneAlertMachine()
        XCTAssertNil(observe(&machine, 120, 0))
        XCTAssertNil(observe(&machine, 120, 60))
        let preference = WorkoutZoneAlertPreference(alertWhenTooLow: true)
        XCTAssertNil(observe(&machine, 120, 61, preference: preference))
        XCTAssertEqual(observe(&machine, 120, 91, preference: preference), .tooLow)
    }
    func testRepeatsCapAndResetOnConfirmedReturn() {
        var machine = WorkoutZoneAlertMachine()
        XCTAssertNil(observe(&machine, 160, 0))
        XCTAssertEqual(observe(&machine, 160, 30), .tooHigh)
        XCTAssertNil(observe(&machine, 160, 119))
        XCTAssertEqual(observe(&machine, 160, 120), .tooHigh)
        XCTAssertEqual(observe(&machine, 160, 210), .tooHigh)
        XCTAssertNil(observe(&machine, 160, 300))
        XCTAssertEqual(machine.alertCount, 3)
        XCTAssertNil(observe(&machine, 140, 301))
        XCTAssertNil(observe(&machine, 140, 315))
        XCTAssertEqual(observe(&machine, 140, 316), .returned)
        XCTAssertEqual(machine.alertCount, 0)
        XCTAssertNil(observe(&machine, 160, 317))
        XCTAssertEqual(observe(&machine, 160, 347), .tooHigh)
    }
    func testReturnRequiresFiredAlertAndCanBeMuted() {
        var machine = WorkoutZoneAlertMachine()
        XCTAssertNil(observe(&machine, 160, 0))
        XCTAssertNil(observe(&machine, 140, 10))
        XCTAssertNil(observe(&machine, 140, 25))
        XCTAssertNil(observe(&machine, 160, 26))
        XCTAssertEqual(observe(&machine, 160, 56), .tooHigh)
        let preference = WorkoutZoneAlertPreference(buzzWhenBackInZone: false)
        XCTAssertNil(observe(&machine, 140, 57, preference: preference))
        XCTAssertNil(observe(&machine, 140, 72, preference: preference))
        XCTAssertEqual(machine.alertCount, 0)
    }
    func testGapsCancelDwellAndKeepCap() {
        var machine = WorkoutZoneAlertMachine()
        XCTAssertNil(observe(&machine, 160, 0))
        XCTAssertNil(observe(&machine, nil, 29))
        XCTAssertNil(observe(&machine, 160, 100))
        XCTAssertNil(observe(&machine, 160, 129))
        XCTAssertEqual(observe(&machine, 160, 130), .tooHigh)
        machine.interrupt()
        XCTAssertNil(observe(&machine, 160, 200))
        XCTAssertEqual(observe(&machine, 160, 230), .tooHigh)
        machine.interrupt()
        XCTAssertNil(observe(&machine, 160, 300))
        XCTAssertEqual(observe(&machine, 160, 330), .tooHigh)
        machine.interrupt()
        XCTAssertNil(observe(&machine, 160, 500))
        XCTAssertNil(observe(&machine, 160, 530))
        XCTAssertEqual(machine.alertCount, 3)
    }
    func testPauseResetClearsExcursion() {
        var machine = WorkoutZoneAlertMachine()
        _ = observe(&machine, 160, 0)
        XCTAssertEqual(observe(&machine, 160, 30), .tooHigh)
        machine.reset()
        XCTAssertNil(observe(&machine, 140, 50))
        XCTAssertNil(observe(&machine, 140, 65))
        XCTAssertNil(observe(&machine, 160, 66))
        XCTAssertEqual(observe(&machine, 160, 96), .tooHigh)
    }
    func testManualPresetPersistsUntilResetAndInvalidOverrideIsIgnored() {
        let suite = "zone-manual-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preference = WorkoutZoneAlertPreference(target: .zoneTwo,
            manualZoneTwo: .init(lower: 131, upper: 144, source: .manual))
        WorkoutZoneAlertPreferenceStore(defaults: defaults).set(preference, for: .walk)
        let saved = WorkoutZoneAlertPreferenceStore(defaults: defaults).preference(for: .walk)
        XCTAssertEqual(saved.resolvedZoneTwo(nil)?.range, 131...144)
        let automatic = ZoneTwoRange(lower: 140, upper: 155, source: .restingHeartRate)
        XCTAssertEqual(saved.resolvedZoneTwo(automatic)?.range, 131...144)
        preference.manualZoneTwo = nil
        XCTAssertEqual(preference.resolvedZoneTwo(automatic), automatic)
        preference.manualZoneTwo = .init(lower: 150, upper: 130, source: .manual)
        XCTAssertEqual(preference.resolvedZoneTwo(automatic), automatic)
    }

    func testOldPreferenceJSONMigrates() throws {
        let old = Data(#"{"target":{"zone":{"_0":2}},"playSound":true}"#.utf8)
        let preference = try JSONDecoder().decode(WorkoutZoneAlertPreference.self, from: old)
        XCTAssertEqual(preference.target, .zone(2))
        XCTAssertTrue(preference.playSound)
        XCTAssertFalse(preference.alertWhenTooLow)
        XCTAssertTrue(preference.buzzWhenBackInZone)
        XCTAssertEqual(preference.warmUpMinutes, 8)
        XCTAssertNil(preference.manualZoneTwo)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutZoneAlertPreference.self, from: JSONEncoder().encode(preference)), preference)
    }
}
