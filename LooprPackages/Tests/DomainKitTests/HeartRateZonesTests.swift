import DomainKit
import XCTest

final class HeartRateZonesTests: XCTestCase {
    func testTanakaAndNoAge() {
        let settings = HeartRateZoneSettings()
        XCTAssertNil(settings.resolved(age: nil))
        XCTAssertNil(settings.resolved(age: 8))
        XCTAssertEqual(HeartRateZoneSettings(manualMaximum: 175).resolved(age: nil)?.source, .manual)
        let zones = settings.resolved(age: 40)!
        XCTAssertEqual(zones.maximum, 180)
        XCTAssertEqual(zones.source, .estimated)
        XCTAssertEqual(zones.edges, [50, 60, 70, 80, 90, 100])
        XCTAssertEqual(zones.bpmRange(for: 2), 108...125)
        XCTAssertEqual(zones.number(for: 108), 2)
        XCTAssertEqual(zones.number(for: 89), 0)
    }

    func testReliableSustainedObservedRaiseAndReset() {
        var settings = HeartRateZoneSettings()
        settings.observe((0...9).map { ReliableHeartRateSample(time: Double($0), bpm: 188, goodSignal: true) }, age: 40)
        XCTAssertNil(settings.observedMaximum)
        settings.observe((0...10).map { ReliableHeartRateSample(time: Double($0), bpm: 188, goodSignal: true) }, age: 40)
        XCTAssertEqual(settings.resolved(age: 40)?.maximum, 188)
        XCTAssertEqual(settings.resolved(age: 40)?.source, .observed)
        settings.manualMaximum = 170
        XCTAssertEqual(settings.resolved(age: 40)?.maximum, 170)
        XCTAssertEqual(settings.resolved(age: 40)?.source, .manual)
        settings.resetMaximum()
        XCTAssertEqual(settings.resolved(age: 40)?.maximum, 188)
    }

    func testPoorSignalGapAndLowerReadingsDoNotRaise() {
        var settings = HeartRateZoneSettings()
        settings.observe((0...12).map { ReliableHeartRateSample(time: Double($0), bpm: 190, goodSignal: $0 != 5) }, age: 40)
        XCTAssertNil(settings.observedMaximum)
        settings.observe((0...10).map { ReliableHeartRateSample(time: Double($0 * 3), bpm: 190, goodSignal: true) }, age: 40)
        XCTAssertNil(settings.observedMaximum)
        settings.observe((0...12).map { ReliableHeartRateSample(time: Double($0), bpm: 170, goodSignal: true) }, age: 40)
        XCTAssertNil(settings.observedMaximum)
    }

    func testBoundaryOrderingMinimumGapAndReset() {
        var settings = HeartRateZoneSettings()
        XCTAssertFalse(settings.setBoundaries([55, 59, 80, 90]))
        XCTAssertFalse(settings.setBoundaries([60, 70, 90, 80]))
        XCTAssertFalse(settings.setBoundaries([60, 70, 80]))
        XCTAssertTrue(settings.setBoundaries([55, 65, 75, 85]))
        XCTAssertEqual(settings.resolved(age: 40)?.bpmRange(for: 2), 99...116)
        settings.resetBoundaries()
        XCTAssertEqual(settings.innerBoundaries, HeartRateZoneSettings.defaultBoundaries)
    }

    func testReserveBoundariesAndClassification() {
        let zones = HeartRateZoneSettings(manualMaximum: 200).resolved(age: nil, restingNights: [50, 60])!
        XCTAssertEqual(zones.restingHeartRate, 55)
        XCTAssertEqual((1...5).compactMap { zones.bpmRange(for: $0)?.lowerBound }, [128, 142, 157, 171, 186])
        XCTAssertEqual(zones.bpmRange(for: 2), 142...156)
        XCTAssertEqual(zones.number(for: 156), 2)
        XCTAssertEqual(zones.number(for: 157), 3)
        XCTAssertEqual(zones.number(for: 127), 0)
        XCTAssertEqual(zones.calculationSource, "From your resting and max heart rate")
    }

    func testInvalidRestingValuesKeepMaximumScale() {
        let zones = HeartRateZoneSettings(manualMaximum: 200).resolved(age: nil, restingNights: [.nan, 0, 250])!
        XCTAssertNil(zones.restingHeartRate)
        XCTAssertEqual(zones.bpmRange(for: 2), 120...139)
        XCTAssertEqual(zones.number(for: 140), 3)
    }

    func testPersistenceRoundTrip() throws {
        let original = HeartRateZoneSettings(observedMaximum: 195, manualMaximum: 188,
                                             innerBoundaries: [58, 68, 78, 88])
        XCTAssertEqual(try JSONDecoder().decode(HeartRateZoneSettings.self, from: JSONEncoder().encode(original)), original)
        let invalid = Data("{\"manualMaximum\":300,\"innerBoundaries\":[70,60,80,90]}".utf8)
        let restored = try JSONDecoder().decode(HeartRateZoneSettings.self, from: invalid)
        XCTAssertNil(restored.manualMaximum)
        XCTAssertEqual(restored.innerBoundaries, HeartRateZoneSettings.defaultBoundaries)
    }
}
