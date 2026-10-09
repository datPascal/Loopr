import BluetoothKit
import Foundation
import XCTest

private actor RecordingRestorationDriver: RestorationSessionDriver {
    enum Call: Equatable {
        case validate(UInt64)
        case resume(UInt64, Bool, Set<UUID>)
        case cancel(UInt64)
    }

    private(set) var calls: [Call] = []
    var validation = AdoptionRestorationValidation(serviceValidated: true, characteristicsValidated: true)

    func validateOrRediscover(
        snapshot: AdoptionRestorationSnapshot,
        generation: UInt64,
        ownerToken: UUID
    ) async throws -> AdoptionRestorationValidation {
        calls.append(.validate(generation))
        return validation
    }

    func resume(
        snapshot: AdoptionRestorationSnapshot,
        context: AdoptionRestorationResumeContext
    ) async throws {
        calls.append(.resume(context.generation, context.historyBurstDiscarded, context.parsers.allIDs))
    }

    func cancel(context: AdoptionRestorationResumeContext) async {
        calls.append(.cancel(context.generation))
    }

    func recordedCalls() -> [Call] { calls }
}

private actor BlockingRestorationDriver: RestorationSessionDriver {
    private var resumeContinuation: CheckedContinuation<Void, Error>?
    private var resumeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStartResume = false
    private(set) var cancelledGenerations: [UInt64] = []

    func validateOrRediscover(
        snapshot: AdoptionRestorationSnapshot,
        generation: UInt64,
        ownerToken: UUID
    ) async throws -> AdoptionRestorationValidation {
        AdoptionRestorationValidation(serviceValidated: true, characteristicsValidated: true)
    }

    func resume(
        snapshot: AdoptionRestorationSnapshot,
        context: AdoptionRestorationResumeContext
    ) async throws {
        didStartResume = true
        let waiters = resumeStartWaiters
        resumeStartWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        try await withCheckedThrowingContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func cancel(context: AdoptionRestorationResumeContext) async {
        cancelledGenerations.append(context.generation)
        let continuation = resumeContinuation
        resumeContinuation = nil
        continuation?.resume(throwing: RestorationCoordinatorError.staleRestoration)
    }

    func resumeStarted() -> Bool { didStartResume }

    func waitForResumeStart() async {
        if didStartResume { return }
        await withCheckedContinuation { continuation in
            if didStartResume {
                continuation.resume()
            } else {
                resumeStartWaiters.append(continuation)
            }
        }
    }

    func recordedCancelledGenerations() -> [UInt64] { cancelledGenerations }
}

private func validRestoredSnapshot(
    shape: AdoptionRestorationShape,
    peripheral: UUID = UUID()
) -> AdoptionRestorationSnapshot {
    AdoptionRestorationSnapshot(
        shape: shape,
        peripheralIdentifier: peripheral,
        serviceUUIDs: [AdoptionRestorationGATT.service],
        characteristics: [
            AdoptionRestoredCharacteristic(
                uuid: AdoptionRestorationGATT.command,
                supportsWriteWithResponse: true
            ),
            AdoptionRestoredCharacteristic(uuid: AdoptionRestorationGATT.response, supportsNotify: true),
            AdoptionRestoredCharacteristic(uuid: AdoptionRestorationGATT.events, supportsNotify: true),
            AdoptionRestoredCharacteristic(uuid: AdoptionRestorationGATT.data, supportsNotify: true)
        ],
        hadActiveHistoryBurst: true
    )
}

final class RestorationTests: XCTestCase {
    func testMidConnectRestorationValidatesBeforeResumeWithFreshParsers() async throws {
        let driver = RecordingRestorationDriver()
        let registry = RestorationOwnerRegistry()
        let coordinator = RestorationCoordinator(driver: driver, ownerRegistry: registry)

        let outcome = try await coordinator.restore(validRestoredSnapshot(shape: .midConnect))
        XCTAssertTrue(outcome.resumed)
        XCTAssertEqual(outcome.generation, 1)
        XCTAssertEqual(outcome.parserSet?.allIDs.count, 3)
        let ownerCount = await registry.ownerCount()
        XCTAssertEqual(ownerCount, 1)

        let calls = await driver.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        guard case .validate(1) = calls[0] else { return XCTFail("validation must happen first") }
        guard case let .resume(generation, discarded, parserIDs) = calls[1] else {
            return XCTFail("resume must happen after validation")
        }
        XCTAssertEqual(generation, 1)
        XCTAssertTrue(discarded)
        XCTAssertEqual(parserIDs, outcome.parserSet?.allIDs)
    }

    func testMidDrainRestorationAllocatesNewGenerationAndDoesNotResumeStaleBurst() async throws {
        let driver = RecordingRestorationDriver()
        let registry = RestorationOwnerRegistry()
        let coordinator = RestorationCoordinator(driver: driver, ownerRegistry: registry)

        let first = try await coordinator.restore(validRestoredSnapshot(shape: .midDrain))
        let second = try await coordinator.restore(validRestoredSnapshot(shape: .midDrain))

        XCTAssertEqual(second.generation, first.generation + 1)
        XCTAssertNotEqual(first.parserSet?.allIDs, second.parserSet?.allIDs)
        let ownerCount = await registry.ownerCount()
        XCTAssertEqual(ownerCount, 1)
        let calls = await driver.recordedCalls()
        let resumes = calls.compactMap { call -> (UInt64, Bool)? in
            guard case let .resume(generation, discarded, _) = call else { return nil }
            return (generation, discarded)
        }
        XCTAssertEqual(resumes.map(\.0), [1, 2])
        XCTAssertEqual(resumes.map(\.1), [true, true])
    }

    func testUnknownPeripheralRestorationIsIgnoredWithoutRediscoveryOrResume() async throws {
        let driver = RecordingRestorationDriver()
        let registry = RestorationOwnerRegistry()
        let coordinator = RestorationCoordinator(driver: driver, ownerRegistry: registry)
        let snapshot = AdoptionRestorationSnapshot(
            shape: .unknownPeripheral,
            peripheralIdentifier: nil,
            hadActiveHistoryBurst: true
        )

        let outcome = try await coordinator.restore(snapshot)
        XCTAssertFalse(outcome.resumed)
        XCTAssertTrue(outcome.ignoredUnknownPeripheral)
        XCTAssertNil(outcome.parserSet)
        let ownerCount = await registry.ownerCount()
        let calls = await driver.recordedCalls()
        XCTAssertEqual(ownerCount, 0)
        XCTAssertTrue(calls.isEmpty)
    }

    func testRestoredGATTValidationRequiresExactServiceAndProperties() {
        let valid = validRestoredSnapshot(shape: .midConnect)
        let result = AdoptionRestorationGATT.validate(valid)
        XCTAssertTrue(result.isReady)

        let extraService = AdoptionRestorationSnapshot(
            shape: .midConnect,
            peripheralIdentifier: UUID(),
            serviceUUIDs: [AdoptionRestorationGATT.service, UUID()],
            characteristics: valid.characteristics
        )
        XCTAssertFalse(AdoptionRestorationGATT.validate(extraService).isReady)

        let duplicateCharacteristic = AdoptionRestorationSnapshot(
            shape: .midConnect,
            peripheralIdentifier: UUID(),
            serviceUUIDs: [AdoptionRestorationGATT.service],
            characteristics: valid.characteristics + [valid.characteristics[0]]
        )
        XCTAssertFalse(AdoptionRestorationGATT.validate(duplicateCharacteristic).isReady)

        let missingNotify = AdoptionRestoredCharacteristic(uuid: AdoptionRestorationGATT.data)
        let invalid = AdoptionRestorationSnapshot(
            shape: .midConnect,
            peripheralIdentifier: UUID(),
            serviceUUIDs: [AdoptionRestorationGATT.service],
            characteristics: [
                AdoptionRestoredCharacteristic(uuid: AdoptionRestorationGATT.command, supportsWriteWithResponse: true),
                AdoptionRestoredCharacteristic(uuid: AdoptionRestorationGATT.response, supportsNotify: true),
                AdoptionRestoredCharacteristic(uuid: AdoptionRestorationGATT.events, supportsNotify: true),
                missingNotify
            ]
        )
        let invalidResult = AdoptionRestorationGATT.validate(invalid)
        XCTAssertFalse(invalidResult.isReady)
    }

    func testRestorationCannotCreateSecondCentralOwner() async throws {
        let driver = RecordingRestorationDriver()
        let registry = RestorationOwnerRegistry()
        let first = RestorationCoordinator(driver: driver, ownerRegistry: registry)
        let second = RestorationCoordinator(driver: driver, ownerRegistry: registry)
        _ = try await first.restore(validRestoredSnapshot(shape: .midConnect))

        do {
            _ = try await second.restore(validRestoredSnapshot(shape: .midConnect))
            XCTFail("second restoration owner was unexpectedly accepted")
        } catch RestorationCoordinatorError.ownerAlreadyHeld {
            // Expected: normal and restored paths share one owner registry.
        }
        let ownerCount = await registry.ownerCount()
        XCTAssertEqual(ownerCount, 1)
    }

    func testInvalidationCancelsInFlightResumeAndReleasesOwner() async throws {
        let driver = BlockingRestorationDriver()
        let registry = RestorationOwnerRegistry()
        let coordinator = RestorationCoordinator(driver: driver, ownerRegistry: registry)
        let task = Task {
            try await coordinator.restore(validRestoredSnapshot(shape: .midConnect))
        }

        await driver.waitForResumeStart()
        let resumeStarted = await driver.resumeStarted()
        XCTAssertTrue(resumeStarted)
        await coordinator.invalidateCurrentRestoration()

        do {
            _ = try await task.value
            XCTFail("invalidated restoration unexpectedly resumed")
        } catch RestorationCoordinatorError.staleRestoration {
            // Expected: cancellation wakes the suspended driver and the old
            // generation remains stale at the coordinator seam.
        }

        let cancelledGenerations = await driver.recordedCancelledGenerations()
        XCTAssertEqual(cancelledGenerations, [1])
        let ownerCount = await registry.ownerCount()
        XCTAssertEqual(ownerCount, 0)
        let currentContext = await coordinator.currentResumeContext()
        XCTAssertNil(currentContext)
    }
}
