import Foundation
import ProtocolKit
import XCTest
@testable import SyncKit

final class Gen5CanonicalMappingTests: XCTestCase {
    func testV18MapsOnlyMeasuredFieldsAndKeepsMissingValuesAbsent() {
        // OpenStrap edge@82b094c3:lib/ble/ble_engine.dart:87-113.
        let sample = Gen5V18Sample(
            timestampSeconds: 1_780_916_150,
            recordIndex: 25_443_699,
            heartRate: 102,
            rrIntervalsMilliseconds: [602, 613],
            dynamicAccelerationG: nil,
            gravityG: [-0.7252, 0.2, 0.8]
        )
        let raw = Data([0x2F, 18])
        let record = Gen5CanonicalMapping.record(from: sample, raw: raw)
        XCTAssertEqual(record.bandCounter, 25_443_699)
        XCTAssertEqual(record.heartRate, 102)
        XCTAssertEqual(record.rrBeats.map(\.intervalMilliseconds), [602, 613])
        XCTAssertEqual(try XCTUnwrap(record.gravityX), -0.7252, accuracy: 0.0001)
        XCTAssertNil(record.ppgGreen)
        XCTAssertNil(record.skinContact)
        XCTAssertNil(record.spo2RedRaw)
        XCTAssertNil(record.unidentified68)
        XCTAssertEqual(record.rawPayload, raw)
    }
}
