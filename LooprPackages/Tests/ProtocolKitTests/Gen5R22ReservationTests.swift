import XCTest
@testable import ProtocolKit

final class Gen5R22AtomicReservationTests: XCTestCase {
    func testReservationClaimsAllSixteenOrNone() async throws {
        let allocator = Gen5R22SequenceAllocator()
        let first = try await allocator.reserveSixteen(startingAt: 250)
        XCTAssertEqual(first.sequences, [250, 251, 252, 253, 254, 255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        let beforeCollision = await allocator.reservationCount()
        XCTAssertEqual(beforeCollision, 16)
        do {
            _ = try await allocator.reserveSixteen(startingAt: 0)
            XCTFail("overlap must reject the entire reservation")
        } catch {
            XCTAssertEqual(error as? Gen5R22ReservationError, .collision)
        }
        let afterCollision = await allocator.reservationCount()
        XCTAssertEqual(afterCollision, 16)
    }

    func testTypedStoreRejectsOutsideReservationAndBoundsMemory() async throws {
        let reservation = try await Gen5R22SequenceAllocator().reserveSixteen(startingAt: 1)
        var store = Gen5R22FrameStore(reservation: reservation)
        try store.append(sequence: 1, bytes: Data([1, 2]))
        XCTAssertThrowsError(try store.append(sequence: 100, bytes: Data()))
        XCTAssertThrowsError(try store.append(sequence: 2, bytes: Data(repeating: 0, count: Gen5R22FrameStore.maximumBytes)))
        XCTAssertEqual(store.frames.count, 1)
    }
}

final class Gen5V20LayoutResolutionTests: XCTestCase {
    func testSyntheticEvidenceCannotGraduateCompetingLayout() {
        XCTAssertFalse(Gen5V20Policy.metricMappingEnabled)
        guard case .unresolvedRawArchiveOnly(let reason) = Gen5V20Policy.resolution else {
            return XCTFail("v20 must remain raw-only")
        }
        XCTAssertTrue(reason.contains("real captures"))
    }
}
