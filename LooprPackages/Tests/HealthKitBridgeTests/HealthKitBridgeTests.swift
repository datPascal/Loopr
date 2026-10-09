import Foundation
import HealthKitBridge
import XCTest
#if canImport(HealthKit)
import HealthKit
#endif

private actor AuthorizationSpy: HealthAuthorizationClient {
    var requests: [HealthAuthorizationScope] = []
    var states: [HealthDataType: HealthAuthorizationState] = [:]
    var result = true
    var shouldFail = false
    func request(_ scope: HealthAuthorizationScope) async throws -> Bool {
        if shouldFail { throw AuthorizationStubFailure.failed }
        requests.append(scope); return result
    }
    func status(for type: HealthDataType) async -> HealthAuthorizationState {
        states[type, default: .notDetermined]
    }
    func set(_ state: HealthAuthorizationState, for type: HealthDataType) { states[type] = state }
    func setResult(_ value: Bool) { result = value }
    func setFailure(_ value: Bool) { shouldFail = value }
    func count() -> Int { requests.count }
}
private enum AuthorizationStubFailure: Error { case failed }

private actor QueryStub: AnchoredHealthQueryClient {
    let result: AnchoredHealthChanges
    init(result: AnchoredHealthChanges) { self.result = result }
    func changes(for type: HealthDataType, after anchor: Data?) async throws -> AnchoredHealthChanges { result }
}

private enum SaveFailure: Error { case rejected }
private actor ExportSpy: HealthExportClient {
    var saved: [UUID] = []
    var failOnce: Set<UUID> = []
    func save(_ object: HealthExportObject) async throws {
        if failOnce.remove(object.id) != nil { throw SaveFailure.rejected }
        saved.append(object.id)
    }
    func failFirst(_ id: UUID) { failOnce.insert(id) }
    func writes() -> [UUID] { saved }
}

final class HealthKitAuthorizationTests: XCTestCase {
    #if canImport(HealthKit)
    func testRevokedWriteAccessCannotBeReportedAsSuccessfulDeletion() {
        let denied = NSError(domain: HKError.errorDomain, code: HKError.errorAuthorizationDenied.rawValue)
        let unrequested = NSError(domain: HKError.errorDomain, code: HKError.errorAuthorizationNotDetermined.rawValue)
        XCTAssertFalse(HealthKitDeletionErrorPolicy.canIgnore(denied))
        XCTAssertTrue(HealthKitDeletionErrorPolicy.canIgnore(unrequested))
    }
    #endif
    func testNoColdLaunchRequestAndContextualScopes() async throws {
        let spy = AuthorizationSpy()
        let coordinator = ContextualHealthAuthorization(client: spy)
        let initialCount = await coordinator.requestCount
        XCTAssertEqual(initialCount, 0)
        let body = try await coordinator.enable(.bodyCompositionImport)
        XCTAssertEqual(body.read, [.height, .bodyMass, .bodyFatPercentage, .leanBodyMass])
        XCTAssertFalse(body.read.contains(.dateOfBirth))
        let age = try await coordinator.enable(.ageInsightsImport)
        XCTAssertEqual(age.read, [.dateOfBirth, .vo2Max])
        let requestCount = await spy.count()
        XCTAssertEqual(requestCount, 2)
    }

    func testCancellationAbsentAndRevocationAreHonest() async throws {
        let spy = AuthorizationSpy()
        let coordinator = ContextualHealthAuthorization(client: spy)
        await spy.setResult(false)
        do { _ = try await coordinator.enable(.bodyCompositionImport); XCTFail("expected cancellation") }
        catch { XCTAssertEqual(error as? HealthAuthorizationError, .cancelled) }
        await spy.set(.unavailable, for: .height)
        let unavailable = await coordinator.currentState(for: [.height])
        XCTAssertEqual(unavailable, .unavailable)
        await spy.set(.authorized, for: .height)
        let authorized = await coordinator.currentState(for: [.height])
        XCTAssertEqual(authorized, .authorized)
        await spy.set(.denied, for: .height)
        let denied = await coordinator.currentState(for: [.height])
        XCTAssertEqual(denied, .denied)
        XCTAssertEqual(
            HealthRevocationProjection.screenState(authorization: .denied, hasCachedValue: true),
            .permissionDenied,
            "A revoked type must never keep presenting a cached value as current"
        )
    }

    func testEveryOptionalTypeHasOneConfirmedHealthKitIdentifier() {
        let identifiers = HealthDataType.allCases.map(HealthObjectIdentifier.identifier(for:))
        XCTAssertEqual(identifiers.count, 6)
        XCTAssertEqual(Set(identifiers).count, 6)
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("HK") })
    }

    func testRequestFailurePropagatesWithoutInventingAuthorization() async {
        let spy = AuthorizationSpy(); await spy.setFailure(true)
        let coordinator = ContextualHealthAuthorization(client: spy)
        do { _ = try await coordinator.enable(.ageInsightsImport); XCTFail("expected request failure") }
        catch { XCTAssertTrue(error is AuthorizationStubFailure) }
        let state = await coordinator.currentState(for: [.dateOfBirth])
        XCTAssertEqual(state, .notDetermined)
    }
}

final class HealthKitImportProvenanceTests: XCTestCase {
    func testProvenanceRoundTripAndDeletionDoesNotDropRow() async throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = ImportedHealthSample(id: id, type: .bodyMass, source: "Fixture Watch",
            device: "Watch7,4", unit: "kg", value: 72.5, startDate: start,
            endDate: start.addingTimeInterval(1), importedAt: start.addingTimeInterval(10))
        let ledger = HealthImportLedger()
        let importer = AnchoredHealthImporter(query: QueryStub(result: .init(
            samples: [sample], deletedSampleIDs: [], nextAnchor: Data([1, 2, 3]))), ledger: ledger)
        try await importer.importChanges(for: .bodyMass, now: start.addingTimeInterval(20))
        let stored = await ledger.sample(id: id)
        let anchor = await ledger.anchor(for: .bodyMass)
        XCTAssertEqual(stored, sample)
        XCTAssertEqual(anchor, Data([1, 2, 3]))

        await ledger.apply(.init(samples: [], deletedSampleIDs: [id], nextAnchor: Data([4])),
                           for: .bodyMass, deletedAt: start.addingTimeInterval(30))
        let allSamples = await ledger.allSamples()
        let deletionState = await ledger.sample(id: id)?.deletionState
        XCTAssertEqual(allSamples.count, 1)
        XCTAssertEqual(deletionState, .deleted(at: start.addingTimeInterval(30)))
    }


    func testAnchorAndAllSevenProvenanceFieldsSurviveProcessRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "health-import-ledger.json")
        let id = UUID(); let start = Date(timeIntervalSince1970: 100)
        let sample = ImportedHealthSample(
            id: id, type: .leanBodyMass, source: "Fixture Source", device: "Fixture Device",
            unit: "kg", value: 61.2, startDate: start, endDate: start.addingTimeInterval(2),
            importedAt: start.addingTimeInterval(4)
        )
        let original = HealthImportLedger(persistenceURL: url)
        await original.apply(.init(samples: [sample], deletedSampleIDs: [], nextAnchor: Data([9, 8, 7])),
                             for: .leanBodyMass, deletedAt: start)
        let restored = HealthImportLedger(persistenceURL: url)
        let restoredSample = await restored.sample(id: id)
        let restoredAnchor = await restored.anchor(for: .leanBodyMass)
        XCTAssertEqual(restoredSample, sample)
        XCTAssertEqual(restoredAnchor, Data([9, 8, 7]))
    }
}

final class HealthKitExportMappingTests: XCTestCase {
    func testAllowlistIsExactAndSDNNMappingIsUnambiguous() throws {
        XCTAssertEqual(Set(ExportMetricKind.allCases.map(\.rawValue)), Set([
            "heartRate", "restingHeartRate", "heartRateVariabilitySDNN", "respiratoryRate",
            "sleepStages", "steps", "activeEnergy", "completedWorkout"
        ]))
        XCTAssertEqual(try HealthExportFirewall.metric(named: "heartRateVariabilitySDNN"),
                       .heartRateVariabilitySDNN)
    }
}

final class HealthKitNeverExportFirewallTests: XCTestCase {
    func testEveryForbiddenMetricIsRejected() {
        for name in HealthExportFirewall.forbidden {
            XCTAssertThrowsError(try HealthExportFirewall.metric(named: name))
        }
    }
}

final class HealthKitExportRetryTests: XCTestCase {
    private func object(_ id: String) -> HealthExportObject {
        .init(id: UUID(uuidString: id)!, metric: .steps, value: 100, unit: "count",
              startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 1))
    }

    func testPartialFailureRemainsRetryableAndSuccessIsIdempotent() async throws {
        let first = object("00000000-0000-0000-0000-000000000001")
        let second = object("00000000-0000-0000-0000-000000000002")
        let client = ExportSpy()
        await client.failFirst(first.id)
        let ledger = HealthExportLedger()
        let scheduler = HealthExportScheduler(client: client, ledger: ledger)
        try await scheduler.export([first, second], now: .init(timeIntervalSince1970: 10))
        if case .failed = try await ledger.status(for: first.id) {} else { XCTFail("failure lost") }
        try await scheduler.export([first, second], now: .init(timeIntervalSince1970: 20))
        let writes = await client.writes()
        XCTAssertEqual(writes, [second.id, first.id])
    }

    func testDSTDayWindowsUseCalendarBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let spring = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 3, day: 9, hour: 12)))
        let fall = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 11, day: 2, hour: 12)))
        XCTAssertEqual(HealthDateWindows.localDay(containing: spring, calendar: calendar)?.duration, 23 * 3600)
        XCTAssertEqual(HealthDateWindows.localDay(containing: fall, calendar: calendar)?.duration, 25 * 3600)
    }

    func testPerObjectExportLedgerSurvivesProcessRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "health-export-ledger.json")
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let first = HealthExportLedger(persistenceURL: url)
        try await first.set(.failed(message: "fixture"), for: id)
        let restored = HealthExportLedger(persistenceURL: url)
        let status = try await restored.status(for: id)
        XCTAssertEqual(status, .failed(message: "fixture"))
    }

    func testCorruptExportLedgerFailsClosed() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-corrupt-health-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not-json".utf8).write(to: url)
        let ledger = HealthExportLedger(persistenceURL: url)

        do {
            _ = try await ledger.status(for: UUID())
            XCTFail("corrupt export state must block access")
        } catch {
            XCTAssertEqual(error as? HealthExportLedgerError, .unreadable)
        }
    }

    func testExportLedgerWriteFailureRollsBackInMemoryState() async throws {
        let blockedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loopr-health-export-write-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blockedDirectory) }
        try Data().write(to: blockedDirectory)
        let ledger = HealthExportLedger(
            persistenceURL: blockedDirectory.appendingPathComponent("export-ledger.json")
        )
        let id = UUID()

        do {
            try await ledger.set(.pending, for: id)
            XCTFail("an export ledger write failure must be reported")
        } catch {
        }
        let rows = try await ledger.allRows()
        XCTAssertTrue(rows.isEmpty)
    }
}
