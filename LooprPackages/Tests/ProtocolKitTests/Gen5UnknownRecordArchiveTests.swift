import XCTest
@testable import ProtocolKit

final class Gen5UnknownRecordArchiveTests: XCTestCase {
    func testUnknownMGRecordIsArchivedVerbatimWithoutMetricMapping() throws {
        let raw = Data([0x2f, 99, 0x80, 1, 2, 3, 4, 5, 6, 7, 8])
        let decision = try Gen5RecordDecoder().decodeOrArchiveUnknown(raw)
        XCTAssertEqual(decision, .unknownRaw(version: 99, bytes: raw))
    }
}
