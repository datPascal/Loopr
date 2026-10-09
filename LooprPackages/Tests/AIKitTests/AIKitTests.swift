import Foundation
import AIKit
import XCTest

private actor MemoryCredentials: AICredentialStore {
    var value: Data?
    func write(_ value: Data) { self.value = value }
    func read() -> Data? { value }
    func remove() { value = nil }
}
private actor TransportSpy: AITransport {
    var payloads: [Data] = []
    var response = Data("ok".utf8)
    func send(payload: Data, configuration: AIProviderConfiguration, key: Data) async throws -> Data {
        payloads.append(payload); return response
    }
    func count() -> Int { payloads.count }
    func last() -> Data? { payloads.last }
}
private actor FailureTransport: AITransport {
    enum Mode: Sendable { case timeout, http, malformed, cancellation }
    let mode: Mode
    private(set) var count = 0
    init(_ mode: Mode) { self.mode = mode }
    func send(payload: Data, configuration: AIProviderConfiguration, key: Data) async throws -> Data {
        count += 1
        switch mode {
        case .timeout: throw AIProviderFailure.timeout
        case .http: throw AIProviderFailure.http(503)
        case .malformed: return Data()
        case .cancellation: throw CancellationError()
        }
    }
    func requestCount() -> Int { count }
}
private actor LateResponseTransport: AITransport {
    private var continuation: CheckedContinuation<Data, Error>?
    private(set) var cancellationObserved = false

    func send(payload: Data, configuration: AIProviderConfiguration, key: Data) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await markCancelled() }
        }
    }

    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func deliverLateResponse() { continuation?.resume(returning: Data("late".utf8)); continuation = nil }
    private func markCancelled() { cancellationObserved = true }
}
private actor AINotificationSpy: AINotificationScheduling {
    private(set) var calls: [(String, String, Date)] = []
    func scheduleBriefingReady(id: String, day: String, fireDate: Date) { calls.append((id, day, fireDate)) }
    func count() -> Int { calls.count }
}
private struct StableFallback: DeterministicAIFallback {
    let value: Data
    func response(for feature: AIFeature, context: AIContext) -> Data { value }
}
private actor ProposalApplierSpy: AIProposalApplier {
    var values: [AIProposal] = []
    func apply(_ proposal: AIProposal) { values.append(proposal) }
    func count() -> Int { values.count }
}
private func context() -> AIContext {
    .init(metrics: ["recovery": 82], journalText: "private", cycleData: ["phase": "luteal"],
          dateRange: Date(timeIntervalSince1970: 1)...Date(timeIntervalSince1970: 2))
}

final class AINetworkOffDefaultTests: XCTestCase {
    func testFreshAndRemovedProviderMakeZeroRequests() async throws {
        let credentials = MemoryCredentials(); let settings = AISettings(credentials: credentials)
        let transport = TransportSpy(); let client = AIProviderClient(settings: settings, transport: transport)
        do { _ = try await client.request(context: context()); XCTFail("must be off") }
        catch { XCTAssertEqual(error as? AIProviderFailure, .disabled) }
        let initialCount = await transport.count(); XCTAssertEqual(initialCount, 0)
        try await settings.configure(.init(baseURL: URL(string: "https://example.invalid")!, model: "fixture"), apiKey: Data("secret".utf8))
        try await settings.removeProvider()
        do { _ = try await client.request(context: context()); XCTFail("must be off again") } catch {}
        let finalCount = await transport.count(); XCTAssertEqual(finalCount, 0)
        let removedKey = await credentials.read(); XCTAssertNil(removedKey)
    }
}

final class AIContextRedactionTests: XCTestCase {
    func testPreviewIsExactPayloadAndPerRequestExclusionsDoNotPersist() throws {
        let preview = try AIContextBuilder.exactPreview(context: context(), excluding: [.journalText])
        let payload = try AIContextBuilder.payload(context: context(), excluding: [.journalText])
        XCTAssertEqual(Data(preview.utf8), payload)
        XCTAssertFalse(preview.contains("private")); XCTAssertTrue(preview.contains("luteal"))
        let next = try AIContextBuilder.exactPreview(context: context(), excluding: [])
        XCTAssertTrue(next.contains("private"))
    }
}

final class AIProposalConfirmationGateTests: XCTestCase {
    func testProposalAppliesOnlyAfterExplicitConfirmationAndOnce() async throws {
        let ledger = AIProposalLedger(); let applier = ProposalApplierSpy()
        let row = StoredAIProposal(id: UUID(), conversationID: UUID(), proposal: .journal(text: "note", tags: ["tag"]))
        await ledger.store(row)
        let before = await applier.count(); XCTAssertEqual(before, 0)
        try await ledger.confirmAndApply(id: row.id, at: Date(timeIntervalSince1970: 1), using: applier)
        try await ledger.confirmAndApply(id: row.id, at: Date(timeIntervalSince1970: 2), using: applier)
        let after = await applier.count(); XCTAssertEqual(after, 1)
    }

    func testJournalProposalSurvivesRelaunchUnappliedUntilConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "proposals.json")
        let row = StoredAIProposal(id: UUID(), conversationID: UUID(),
                                   proposal: .journal(text: "review me", tags: ["fixture"]))
        let initial = AIProposalLedger(persistenceURL: url)
        await initial.store(row)
        let applier = ProposalApplierSpy()
        let restored = AIProposalLedger(persistenceURL: url)
        let before = await applier.count()
        XCTAssertEqual(before, 0)
        try await restored.confirmAndApply(id: row.id, at: Date(), using: applier)
        try await restored.confirmAndApply(id: row.id, at: Date(), using: applier)
        let after = await applier.count()
        let appliedAt = await restored.proposal(id: row.id)?.appliedAt
        XCTAssertEqual(after, 1)
        XCTAssertNotNil(appliedAt)
    }
}

final class AIConversationDeletionTests: XCTestCase {
    func testConversationDeletionRemovesOrphanProposal() async {
        let proposals = AIProposalLedger(); let conversations = AIConversationStore(proposals: proposals)
        let id = UUID(); let row = StoredAIProposal(id: UUID(), conversationID: id, proposal: .journal(text: "x", tags: []))
        await proposals.store(row); await conversations.save(.init(id: id, messages: ["hello"]))
        await conversations.delete(id: id)
        let conversation = await conversations.conversation(id: id)
        let proposal = await proposals.proposal(id: row.id)
        XCTAssertNil(conversation); XCTAssertNil(proposal)
    }
}

final class AIChartFirewallTests: XCTestCase {
    func testOnlyAllowlistedChartsBuildContext() throws {
        XCTAssertEqual(try AIChartContext.validate("sleepTrend"), .sleepTrend)
        XCTAssertThrowsError(try AIChartContext.validate("rawProtocolDiagnostics"))
    }
}

final class AIKeychainTests: XCTestCase {
    func testProviderRemovalDeletesCredentialImmediately() async throws {
        let credentials = MemoryCredentials(); let settings = AISettings(credentials: credentials)
        let secret = Data("fixture-key-never-persisted".utf8)
        try await settings.configure(.init(baseURL: URL(string: "https://example.invalid")!, model: "fixture"),
                                     apiKey: secret)
        let stored = try await settings.credential()
        XCTAssertEqual(stored, secret)
        try await settings.removeProvider()
        let removed = try await settings.credential()
        let enabled = await settings.isEnabled
        XCTAssertNil(removed)
        XCTAssertFalse(enabled)
    }

    #if canImport(Security)
    func testConcreteStoreUsesBundleDerivedNamedServiceAndAccount() {
        XCTAssertEqual(KeychainCredentialStore.serviceIdentifier(bundleIdentifier: "com.loopr.ios"),
                       "com.loopr.ios.ai-provider")
        XCTAssertEqual(KeychainCredentialStore.account, "openai-compatible-api-key")
    }
    #endif
}

final class AIFailureHandlingTests: XCTestCase {
    func testTimeoutHTTPMalformedAndCancellationAreTypedSingleAttemptFailures() async throws {
        let expected: [(FailureTransport.Mode, AIProviderFailure)] = [
            (.timeout, .timeout), (.http, .http(503)), (.malformed, .malformedResponse),
            (.cancellation, .cancelled)
        ]
        for (mode, failure) in expected {
            let settings = AISettings(credentials: MemoryCredentials())
            try await settings.configure(.init(baseURL: URL(string: "https://example.invalid")!, model: "fixture"),
                                         apiKey: Data("key".utf8))
            let transport = FailureTransport(mode)
            let client = AIProviderClient(settings: settings, transport: transport)
            do { _ = try await client.request(context: context()); XCTFail("expected \(failure)") }
            catch { XCTAssertEqual(error as? AIProviderFailure, failure) }
            let count = await transport.requestCount()
            XCTAssertEqual(count, 1)
        }
    }

    func testDismissCancelsTransportAndDiscardsLateResponse() async throws {
        let settings = AISettings(credentials: MemoryCredentials())
        try await settings.configure(
            .init(baseURL: URL(string: "https://example.invalid")!, model: "fixture"),
            apiKey: Data("key".utf8)
        )
        let transport = LateResponseTransport()
        let client = AIProviderClient(settings: settings, transport: transport)
        let request = Task { try await client.request(context: context()) }
        await transport.waitUntilStarted()
        await client.cancel()
        await transport.deliverLateResponse()

        do {
            _ = try await request.value
            XCTFail("A dismissed request must not publish its late response")
        } catch {
            XCTAssertEqual(error as? AIProviderFailure, .cancelled)
        }
        let cancellationObserved = await transport.cancellationObserved
        XCTAssertTrue(cancellationObserved)
    }
}

final class AINotificationRoutingTests: XCTestCase {
    func testBriefingReadyUsesInjectedCentralScheduler() async throws {
        let spy = AINotificationSpy()
        let bridge = AIBriefingNotificationBridge(scheduler: spy)
        try await bridge.briefingReady(id: "briefing", day: "2026-08-24", fireDate: Date(timeIntervalSince1970: 1))
        let count = await spy.count()
        XCTAssertEqual(count, 1)
    }

    func testAIKitDoesNotLinkUserNotificationsFramework() throws {
        let source = try String(contentsOf: sourceRoot().appendingPathComponent("Sources/AIKit/Placeholder.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("UNUserNotificationCenter"))
        XCTAssertFalse(source.contains("import UserNotifications"))
    }

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

final class AIDeterministicFallbackTests: XCTestCase {
    func testOffAndFailedProviderReturnIdenticalLocalOutput() async throws {
        let stable = Data("deterministic APP-14 output".utf8)
        let disabledSettings = AISettings(credentials: MemoryCredentials())
        let disabled = AIFeatureCoordinator(
            provider: AIProviderClient(settings: disabledSettings, transport: TransportSpy()),
            fallback: StableFallback(value: stable)
        )
        let offResponse = await disabled.response(for: .morningBriefing, context: context())

        let failedSettings = AISettings(credentials: MemoryCredentials())
        try await failedSettings.configure(.init(baseURL: URL(string: "https://example.invalid")!, model: "fixture"),
                                           apiKey: Data("key".utf8))
        let failed = AIFeatureCoordinator(
            provider: AIProviderClient(settings: failedSettings, transport: FailureTransport(.timeout)),
            fallback: StableFallback(value: stable)
        )
        let failureResponse = await failed.response(for: .morningBriefing, context: context())
        XCTAssertEqual(offResponse, failureResponse)
        XCTAssertTrue(offResponse.usedLocalFallback)
    }


    func testCoachAndBriefingUseTheSharedExactContextAndRedactionPath() async throws {
        let settings = AISettings(credentials: MemoryCredentials())
        try await settings.configure(.init(baseURL: URL(string: "https://example.invalid")!, model: "fixture"),
                                     apiKey: Data("key".utf8))
        let transport = TransportSpy()
        let coordinator = AIFeatureCoordinator(
            provider: AIProviderClient(settings: settings, transport: transport),
            fallback: StableFallback(value: Data("fallback".utf8))
        )
        _ = await coordinator.response(for: .coachConversation, context: context(), excluding: [.journalText])
        let coachPayload = await transport.last()
        _ = await coordinator.response(for: .eveningBriefing, context: context(), excluding: [.journalText])
        let briefingPayload = await transport.last()
        let exact = try AIContextBuilder.payload(context: context(), excluding: [.journalText])
        let count = await transport.count()
        XCTAssertEqual(coachPayload, exact)
        XCTAssertEqual(briefingPayload, exact)
        XCTAssertEqual(count, 2)
    }
}
