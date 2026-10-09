import XCTest
@testable import ProtocolKit

final class Gen5ModelIdentityTests: XCTestCase {
    func testSharedServiceNeedsDeviceInformationToNameModel() {
        // noop@5ac2cc2a:Packages/WhoopProtocol/Sources/WhoopProtocol/
        // Whoop5Variant.swift:18-27,58-98 records these DIS values.
        XCTAssertEqual(Gen5ModelIdentityResolver.resolve(modelNumber: nil, serialNumber: nil, hardwareRevision: nil), .unknownGen5)
        XCTAssertEqual(Gen5ModelIdentityResolver.resolve(modelNumber: "MG", serialNumber: "MGB123", hardwareRevision: "WS50_r03"), .whoopMG)
        XCTAssertEqual(Gen5ModelIdentityResolver.resolve(modelNumber: nil, serialNumber: "5AM123", hardwareRevision: nil), .whoopMG)
        XCTAssertEqual(Gen5ModelIdentityResolver.resolve(modelNumber: nil, serialNumber: "5AG123", hardwareRevision: nil), .whoop5)
        XCTAssertEqual(Gen5ModelIdentityResolver.resolve(modelNumber: nil, serialNumber: nil, hardwareRevision: "WG50"), .whoop5)
        XCTAssertEqual(Gen5ModelIdentityResolver.resolve(modelNumber: nil, serialNumber: "5AM123", hardwareRevision: "WG50"), .unknownGen5)
    }
}
