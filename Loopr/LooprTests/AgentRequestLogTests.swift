import AIKit
import Foundation
import StorageKit
import Testing
@testable import Loopr

/// Captures every request body a URLSession sends and answers from a script. No test here can reach a network.
private final class LogStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(status: Int, type: String, body: Data)] = []
    private var bodies: [Data] = []
    var onRequest: (@Sendable (Int) -> Void)?
    func script(_ responses: [(Int, String, Data)]) { lock.withLock { self.responses = responses.map { ($0.0, $0.1, $0.2) }; bodies = [] } }
    func record(_ body: Data) -> Int { lock.withLock { bodies.append(body); return bodies.count - 1 } }
    func next() -> (status: Int, type: String, body: Data) {
        lock.withLock { responses.isEmpty ? (500, "application/json", Data()) : responses.removeFirst() }
    }
    var sent: [Data] { lock.withLock { bodies } }
}
private final class LogStubProtocol: URLProtocol, @unchecked Sendable {
    static let state = LogStubState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
        }
        let index = Self.state.record(body)
        Self.state.onRequest?(index)
        let reply = Self.state.next()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct AgentRequestLogTests {
    private static func toolUse(_ name: String, id: String = "toolu_1") -> Data {
        Data(#"{"type":"message","role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]}"#.utf8)
    }
    private static func final(_ text: String) -> Data {
        Data(#"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"\#(text)"}]}"#.utf8)
    }
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogStubProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func record(at date: Date, body: String = "{}", purpose: AIRequestPurpose = .chat) -> AIRequestRecord {
        AIRequestRecord(date: date, provider: .anthropic, model: "claude-haiku-5-5", purpose: purpose, body: Data(body.utf8))
    }

    // MARK: The log equals what was sent

    @Test func everyLoggedBodyIsTheExactBytesThatLeftTheDevice() async throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try SQLiteAgentRequestLog(database: database, now: { AgentFixtures.now })
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let stub = LogStubProtocol.state
        stub.script([(200, "application/json", Self.toolUse(AgentToolName.getFood)), (200, "application/json", Self.final("Dinner was late."))])
        stub.onRequest = { index in if index == 0 { suite.set(.food, false) } }   // the switch flips after the tool was advertised
        defer { stub.onRequest = nil }

        let session = Self.session(); defer { session.invalidateAndCancel() }
        let transport = CoachURLSessionTransport(session: session, recorder: log)
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: transport)
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "sk-test-secret")
        let configuration = try #require(try await runtime.selectedConfiguration())
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        let mode = LooprAgentToolMode(runtime: runtime, source: FakeAgentSource(), writes: harness.writes, proposals: harness.center, defaults: suite.defaults,
                                      now: { AgentFixtures.now }, timeZone: { AgentFixtures.zone })
        var chat = AgentFixtures.conversation(); chat.configuration = configuration
        let origin = AskOrigin(screen: "Sleep", day: "Fri 16 Oct", date: AgentFixtures.now)

        let output = try await mode.run(conversation: chat, assistantMessageID: UUID(), origin: origin)
        #expect(output.text == "Dinner was late.")

        let sent = stub.sent
        let logged = try log.records().reversed().map { $0 }
        #expect(sent.count == 2 && logged.count == 2)
        for (record, bytes) in zip(logged, sent) {
            #expect(record.body == bytes, "the log must hold the sent bytes, byte for byte")
            #expect(record.bodyBytes == bytes.count)
            #expect(record.purpose == .toolRound && record.provider == .anthropic && record.model == "claude-haiku-5-5")
            #expect(record.conversationID == chat.id && record.origin == "Sleep, Fri 16 Oct")
            #expect(record.status == .succeeded && record.httpStatus == 200, "didFinish updates the stored row")
            #expect(!String(decoding: record.body, as: UTF8.self).contains("sk-test-secret"), "the key is never part of the body")
        }
        // Round two carries the denied lookup, and the log says so.
        let message = "Food log is off in Your data, so Ask did not read it."
        #expect(logged[0].toolCalls.isEmpty && logged[0].denials.isEmpty)
        #expect(logged[1].toolCalls == [AIRecordedToolCall(name: AgentToolName.getFood, domain: "food", resultBytes: message.utf8.count, isError: true, denied: true)])
        #expect(logged[1].denials == [AIRecordedDenial(toolName: AgentToolName.getFood, domain: "food", message: message)])
        #expect(String(decoding: logged[1].body, as: UTF8.self).contains(message))
        // The first body lists food as an available tool, the second still describes the same request from before the flip.
        #expect(String(decoding: logged[0].body, as: UTF8.self).contains("\"get_food\""))
    }

    @Test func aStreamedChatAndAFoodEstimateAreLoggedToo() async throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try SQLiteAgentRequestLog(database: database, now: { AgentFixtures.now })
        let stub = LogStubProtocol.state
        let sse = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
        stub.script([(200, "text/event-stream", Data(sse.utf8))])
        let session = Self.session(); defer { session.invalidateAndCancel() }
        let transport = CoachURLSessionTransport(session: session, recorder: log)
        var request = CoachChatRequest(configuration: AgentFixtures.configuration(), instructions: "", context: "Summary", messages: [CoachChatMessage(role: .user, text: "Hi")])
        request.recording = AIRequestContext(purpose: .briefing, conversationID: UUID(), origin: nil)
        for try await _ in transport.stream(request, key: "k") {}
        let row = try #require(try log.records().first)
        #expect(row.body == stub.sent[0] && row.purpose == .briefing && row.status == .succeeded)
        #expect(try request.payload() == row.body)
    }

    @Test func aFailedRequestIsStillLogged() async throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try SQLiteAgentRequestLog(database: database, now: { AgentFixtures.now })
        LogStubProtocol.state.script([(429, "application/json", Data(#"{"error":{"type":"rate_limit_error"}}"#.utf8))])
        let session = Self.session(); defer { session.invalidateAndCancel() }
        let transport = CoachURLSessionTransport(session: session, recorder: log)
        let request = CoachAgentRequest(configuration: AgentFixtures.configuration(), instructions: "", context: "", messages: [CoachChatMessage(role: .user, text: "Hi")],
                                        tools: AgentToolRegistry.specs(allowed: [.metrics], capabilities: .init()))
        await #expect(throws: (any Error).self) { _ = try await transport.turn(request, key: "k") }
        let row = try #require(try log.records().first)
        #expect(row.status == .failed && row.httpStatus == 429)
        #expect(row.body == LogStubProtocol.state.sent[0])
    }

    // MARK: Pruning

    @Test func recordsOlderThanThirtyDaysAreDeletedOnWrite() throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = AgentFixtures.now
        let box = ClockBox(clock)
        let log = try SQLiteAgentRequestLog(database: database, now: { box.value })
        let day: TimeInterval = 86_400
        let old = record(at: clock.addingTimeInterval(-31 * day), body: "old")
        let edge = record(at: clock.addingTimeInterval(-29.5 * day), body: "edge")
        let fresh = record(at: clock.addingTimeInterval(-1 * day), body: "fresh")
        // Written long ago, when they were new.
        box.value = clock.addingTimeInterval(-31 * day); log.willSend(old)
        box.value = clock.addingTimeInterval(-29.5 * day); log.willSend(edge)
        #expect(try log.records().count == 2)
        box.value = clock
        log.willSend(fresh)
        let kept = try log.records()
        #expect(kept.map { String(decoding: $0.body, as: UTF8.self) } == ["fresh", "edge"], "newest first, and the 31-day row is gone")
        #expect(try log.record(id: old.id) == nil)
    }

    @Test func pruningAtLaunchUsesTheSameCutoff() throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let box = ClockBox(AgentFixtures.now.addingTimeInterval(-40 * 86_400))
        let log = try SQLiteAgentRequestLog(database: database, now: { box.value })
        let ancient = record(at: box.value); log.willSend(ancient)
        let recent = record(at: AgentFixtures.now.addingTimeInterval(-10 * 86_400)); log.willSend(recent)
        #expect(try log.records().count == 2, "nothing is old yet, from the clock's view")
        try log.prune(now: AgentFixtures.now)
        #expect(try log.records().map(\.id) == [recent.id])
        #expect(AgentRequestLogPolicy.retentionDays == 30)
    }

    @Test func clearRemovesTheLogAndLeavesProposalsAlone() async throws {
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        let log = try SQLiteAgentRequestLog(database: harness.database, now: { AgentFixtures.now })
        log.willSend(record(at: AgentFixtures.now)); log.willSend(record(at: AgentFixtures.now.addingTimeInterval(-60)))
        let made = try await harness.maker().make(tool: AgentToolName.proposeJournalQuestion, args: ["name": "Screens", "question": "Screens late?"])
        let id = UUID()
        try await harness.center.create(StoredAIProposal(id: id, conversationID: UUID(), proposal: made.proposal, card: made.card, createdAt: AgentFixtures.now))
        #expect(try log.records().count == 2)
        try log.clear()
        #expect(try log.records().isEmpty)
        #expect(await (try harness.restarted()).center.proposal(id: id)?.state == .pending)
    }

    @Test func theLogSurvivesARestartInNewestFirstOrder() throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try SQLiteAgentRequestLog(database: database, now: { AgentFixtures.now })
        let older = record(at: AgentFixtures.now.addingTimeInterval(-3_600), body: "older"), newer = record(at: AgentFixtures.now, body: "newer")
        first.willSend(older); first.willSend(newer)
        first.didFinish(id: older.id, status: .failed, httpStatus: 503)
        let second = try SQLiteAgentRequestLog(database: database, now: { AgentFixtures.now })
        let rows = try second.records()
        #expect(rows.map(\.id) == [newer.id, older.id])
        #expect(rows[1].status == .failed && rows[1].httpStatus == 503 && rows[0].status == .sent)
        #expect(try second.record(id: newer.id)?.body == Data("newer".utf8))
    }

    @Test func theInMemoryLogBehavesTheSame() throws {
        let box = ClockBox(AgentFixtures.now)
        let log = InMemoryAgentRequestLog(now: { box.value })
        let old = record(at: AgentFixtures.now.addingTimeInterval(-31 * 86_400)), fresh = record(at: AgentFixtures.now)
        log.willSend(old); log.willSend(fresh)
        #expect(try log.records().map(\.id) == [fresh.id])
        log.didFinish(id: fresh.id, status: .succeeded, httpStatus: 200)
        #expect(try log.record(id: fresh.id)?.status == .succeeded)
        try log.clear()
        #expect(try log.records().isEmpty)
    }

    // MARK: The hub

    @Test func eventsBeforeALogAttachesWaitAndArriveInOrder() throws {
        let hub = AgentRequestLogHub()
        let a = record(at: AgentFixtures.now, body: "a"), b = record(at: AgentFixtures.now.addingTimeInterval(1), body: "b")
        hub.willSend(a); hub.willSend(b)
        hub.didFinish(id: a.id, status: .succeeded, httpStatus: 200)
        let log = InMemoryAgentRequestLog(now: { AgentFixtures.now })
        hub.attach(log)
        #expect(try log.records().map(\.id) == [b.id, a.id])
        #expect(try log.record(id: a.id)?.status == .succeeded)
        let c = record(at: AgentFixtures.now.addingTimeInterval(2), body: "c")
        hub.willSend(c)
        #expect(try log.records().count == 3, "after attaching, sends go straight through")
    }

    // MARK: Export, inventory and deletion

    @Test func theLogIsPartOfYourDataExportsAndCountsUnderOther() throws {
        #expect(YourDataDomain.document("agent") == .other)
        #expect(YourDataDomain.document("patterns") == .journal)
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try SQLiteAgentRequestLog(database: database, now: { AgentFixtures.now })
        log.willSend(record(at: AgentFixtures.now, body: String(repeating: "x", count: 4_000)))
        let stores = YourDataStores(ledgers: [.init(name: "products", database: database)], supportDirectory: root, photosDirectory: root.appendingPathComponent("photos"))
        #expect(try stores.inventory().contentBytes[.other, default: 0] > 4_000)

        let exporter = YourDataExporter(stores: stores, defaultsData: Data(), temporaryDirectory: root)
        let staged = root.appendingPathComponent("staged", isDirectory: true)
        try exporter.stage(.everything, at: staged, now: AgentFixtures.now)
        let table = try Data(contentsOf: staged.appendingPathComponent("products/loopr_product_document.json"))
        let text = String(decoding: table, as: UTF8.self)
        #expect(text.contains("\"namespace\":\"agent\"") && text.contains("\"document_key\":\"log."), "the request log leaves with the export")
    }

    @Test func deletingEverythingEmptiesTheLog() throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try SQLiteAgentRequestLog(database: database, now: { AgentFixtures.now })
        log.willSend(record(at: AgentFixtures.now))
        try database.deleteAllAccountData()
        #expect(try log.records().isEmpty)
    }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
