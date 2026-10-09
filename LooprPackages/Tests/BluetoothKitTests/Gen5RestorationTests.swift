import XCTest
import ProtocolKit
@testable import BluetoothKit

private actor Gen5RestorationDriver: RestorationSessionDriver {
    private(set) var contexts: [AdoptionRestorationResumeContext] = []

    func validateOrRediscover(
        snapshot: AdoptionRestorationSnapshot,
        generation: UInt64,
        ownerToken: UUID
    ) -> AdoptionRestorationValidation {
        AdoptionRestorationGATT.validate(snapshot)
    }

    func resume(
        snapshot: AdoptionRestorationSnapshot,
        context: AdoptionRestorationResumeContext
    ) {
        contexts.append(context)
    }

    func snapshot() -> [AdoptionRestorationResumeContext] { contexts }
}

private func validGen5RestorationSnapshot(
    shape: AdoptionRestorationShape,
    activeBurst: Bool = false
) -> AdoptionRestorationSnapshot {
    AdoptionRestorationSnapshot(
        generation: .gen5,
        shape: shape,
        peripheralIdentifier: shape == .unknownPeripheral ? nil : UUID(),
        serviceUUIDs: shape == .unknownPeripheral ? [] : [GATTProfile.gen5.service],
        characteristics: shape == .unknownPeripheral ? [] : [
            .init(uuid: GATTProfile.gen5.command, supportsWriteWithResponse: true),
            .init(uuid: GATTProfile.gen5.response, supportsNotify: true),
            .init(uuid: GATTProfile.gen5.events, supportsNotify: true),
            .init(uuid: GATTProfile.gen5.data, supportsNotify: true)
        ],
        hadActiveHistoryBurst: activeBurst
    )
}

final class Gen5SingleCentralRestorationTests: XCTestCase {
    func testGen4AndGen5ShareOneOwnerRegistry() async throws {
        let registry = RestorationOwnerRegistry()
        let driver = Gen5RestorationDriver()
        let coordinator = RestorationCoordinator(driver: driver, ownerRegistry: registry)
        _ = try await coordinator.restore(validGen5RestorationSnapshot(shape: .midConnect))
        let ownerCount = await registry.ownerCount()
        XCTAssertEqual(ownerCount, 1)

        let competingOwnerRejected: Bool
        do {
            _ = try await registry.acquire()
            competingOwnerRejected = false
        } catch {
            competingOwnerRejected = (error as? RestorationCoordinatorError) == .ownerAlreadyHeld
        }
        XCTAssertTrue(competingOwnerRejected)
    }
}

final class Gen5RestorationTests: XCTestCase {
    func testEveryRestorationShapeGetsFreshGenerationAndParsers() async throws {
        let driver = Gen5RestorationDriver()
        let coordinator = RestorationCoordinator(driver: driver)

        let first = try await coordinator.restore(validGen5RestorationSnapshot(shape: .midConnect))
        let second = try await coordinator.restore(validGen5RestorationSnapshot(shape: .midDrain, activeBurst: true))
        let unknown = try await coordinator.restore(validGen5RestorationSnapshot(shape: .unknownPeripheral))

        XCTAssertEqual(first.generation + 1, second.generation)
        XCTAssertEqual(second.generation + 1, unknown.generation)
        XCTAssertTrue(first.parserSet!.allIDs.isDisjoint(with: second.parserSet!.allIDs))
        XCTAssertTrue(unknown.ignoredUnknownPeripheral)
        XCTAssertFalse(unknown.resumed)

        let contexts = await driver.snapshot()
        XCTAssertTrue(contexts.allSatisfy(\.historyBurstDiscarded))
        XCTAssertTrue(contexts.allSatisfy(\.backgroundWorkIsHistoryOnly))
    }
}
