import AIKit
import Foundation
import StorageKit
import Testing
@testable import Loopr

/// Captures every request body a URLSession sends and answers from a script, so no test here can reach a network.
private final class LongevityStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(status: Int, type: String, body: Data)] = []
    private var bodies: [Data] = []
    /// Runs after a request body is captured and before the reply, with the request's index.
    var onRequest: (@Sendable (Int) -> Void)?
    func script(_ responses: [(Int, String, Data)]) { lock.withLock { self.responses = responses.map { ($0.0, $0.1, $0.2) }; bodies = [] } }
    func record(_ body: Data) -> Int { lock.withLock { bodies.append(body); return bodies.count - 1 } }
    func next() -> (status: Int, type: String, body: Data) {
        lock.withLock { responses.isEmpty ? (500, "application/json", Data()) : responses.removeFirst() }
    }
    var sent: [Data] { lock.withLock { bodies } }
}
private final class LongevityStubProtocol: URLProtocol, @unchecked Sendable {
    static let state = LongevityStubState()
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

/// The eight Your data switches against the old and new read tools: what each one blocks, what stays off by default, and
/// that Ask still only proposes.
@Suite(.serialized)
struct LongevityAgentAccessTests {
    private static let newTools: [(name: String, domain: String)] = [
        (AgentToolName.getProtocol, "journalAnswers"), (AgentToolName.getAdherence, "journalAnswers"), (AgentToolName.getExperiments, "journalAnswers"),
        (AgentToolName.getSupplements, "supplements"), (AgentToolName.getLabs, "labs"), (AgentToolName.getCapacity, "training"),
        (AgentToolName.getAges, "metrics"),
    ]

    /// Every read tool that reads this domain, with arguments that work against the fixture data.
    private static func lookups(for domain: AgentDataDomain) -> [AgentToolCall] {
        func call(_ name: String, _ arguments: [String: Any] = [:]) -> AgentToolCall { AgentFixtures.call(name, arguments) }
        switch domain {
        case .metrics:
            return [call(AgentToolName.getMetrics, ["metrics": ["rmssd"]]), call(AgentToolName.getSleep),
                    call(AgentToolName.comparePeriods, ["metric": "rmssd", "a": ["from": "2026-10-01", "to": "2026-10-07"],
                                                        "b": ["from": "2026-10-08", "to": "2026-10-14"]]),
                    call(AgentToolName.compareDays, ["metric": "rmssd", "days": ["2026-10-10"]]),
                    call(AgentToolName.listPatterns)]
        case .food: return [call(AgentToolName.getFood)]
        case .training: return [call(AgentToolName.getTraining), call(AgentToolName.getCapacity)]
        case .journalAnswers:
            return [call(AgentToolName.getJournal), call(AgentToolName.getProtocol), call(AgentToolName.getAdherence), call(AgentToolName.getExperiments)]
        case .journalNotes: return [call(AgentToolName.getJournal, ["includeNotes": true])]
        case .cycle: return [call(AgentToolName.getCycle)]
        case .supplements: return [call(AgentToolName.getSupplements)]
        case .labs: return [call(AgentToolName.getLabs)]
        }
    }

    private func executor(_ gate: AgentAccessGate, source: LongevityFakeSource) -> AgentToolExecutor {
        AgentToolExecutor(readers: AgentReaders(gate: gate, source: source), proposals: nil, maker: nil, session: AgentToolSession(),
                          conversationID: UUID(), messageID: UUID(), now: AgentFixtures.now, timeZone: AgentFixtures.zone)
    }

    // MARK: Each of the eight switches

    @Test(arguments: AgentDataDomain.allCases)
    func eachSwitchBlocksItsDataOnEveryToolThatReadsIt(domain: AgentDataDomain) async {
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases).subtracting([domain]))
        let source = LongevityFakeSource()
        let run = executor(AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: source)
        for call in Self.lookups(for: domain) {
            let outcome = await run.execute(call)
            #expect(outcome.denied && outcome.isError, "\(call.name) read \(domain.rawValue) while it was off")
            #expect(outcome.content == "\(domain.title) is off in Your data, so Ask did not read it.", "\(call.name)")
        }
        #expect(source.count(domain.rawValue) == 0, "\(domain.rawValue) was read while it was off")

        // And only that domain: every other lookup still answers.
        for other in AgentDataDomain.allCases where other != domain {
            if other == .journalNotes && domain == .journalAnswers { continue }   // notes ride on the answers read
            for call in Self.lookups(for: other) {
                let outcome = await run.execute(call)
                #expect(!outcome.denied && !outcome.isError, "\(call.name) with only \(domain.rawValue) off: \(outcome.content)")
            }
        }
    }

    @Test(arguments: AgentDataDomain.allCases)
    func anOnSwitchLetsItsToolsRead(domain: AgentDataDomain) async {
        let suite = AgentFixtures.Suite(); suite.setOnly([domain])
        let source = LongevityFakeSource()
        let run = executor(AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: source)
        for call in Self.lookups(for: domain) where !(domain == .journalNotes) {
            // Reading notes needs the answers switch too, so it is checked with both on in the test above.
            let outcome = await run.execute(call)
            #expect(!outcome.denied, "\(call.name) with \(domain.rawValue) on: \(outcome.content)")
        }
    }

    @Test func theAgesToolFollowsTheSwitchBehindEachAge() async throws {
        for (metrics, labs) in [(true, true), (true, false), (false, true), (false, false)] {
            var on: Set<AgentDataDomain> = []
            if metrics { on.insert(.metrics) }
            if labs { on.insert(.labs) }
            let suite = AgentFixtures.Suite(); suite.setOnly(on)
            let source = LongevityFakeSource()
            let outcome = await executor(AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: source)
                .execute(AgentFixtures.call(AgentToolName.getAges))
            if !metrics && !labs {
                #expect(outcome.denied, "both ages are off")
                #expect(source.count("metrics") == 0 && source.count("labs") == 0)
                continue
            }
            let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.content.utf8)) as? [String: Any])
            let hasCardio = (json["cardioAge"] as? [String: Any])?["years"] != nil
            let hasBlood = (json["bloodAge"] as? [String: Any])?["years"] != nil
            #expect(hasCardio == metrics, "Cardio Age follows Band metrics and sleep")
            #expect(hasBlood == labs, "blood age follows Blood tests")
            #expect(source.count("metrics") == (metrics ? 1 : 0) && source.count("labs") == (labs ? 1 : 0))
            #expect((json["looprAge"] as? [String: Any])?["available"] as? Bool == false)
        }
    }

    // MARK: Defaults and saved preferences

    @Test @MainActor func bothNewSwitchesStartOffForAFreshInstall() {
        let suite = AgentFixtures.Suite()   // nothing saved
        let preferences = AgentAccessPreferences(defaults: suite.defaults)
        #expect(!preferences.allows(.supplements) && !preferences.allows(.labs))
        #expect(!AgentAccessPreferences.isAllowed(.supplements, defaults: suite.defaults) && !AgentAccessPreferences.isAllowed(.labs, defaults: suite.defaults))
        #expect(preferences.allows(.metrics) && preferences.allows(.food) && preferences.allows(.training) && preferences.allows(.journalAnswers))
        #expect(!preferences.allows(.journalNotes) && !preferences.allows(.cycle))

        let gate = AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults)
        #expect(gate.allowedDomains == [.metrics, .food, .training, .journalAnswers])
        let advertised = Set(AgentToolRegistry.specs(allowed: gate.allowedDomains, capabilities: .init()).map(\.name))
        #expect(!advertised.contains(AgentToolName.getSupplements) && !advertised.contains(AgentToolName.getLabs))
        #expect(advertised.contains(AgentToolName.getProtocol) && advertised.contains(AgentToolName.getCapacity) && advertised.contains(AgentToolName.getAges))
        let note = gate.instructionNote(today: AgentFixtures.today, timeZone: AgentFixtures.zone)
        #expect(note.contains("Supplements and medication") && note.contains("Blood tests"), "the model is told these are off")
    }

    @Test @MainActor func aPreferenceSavedByBuild21ReadsTheTwoNewSwitchesAsOff() {
        let suite = AgentFixtures.Suite()
        // Build 21 saved six keys, and a person who had turned everything on has six trues.
        suite.defaults.set(["metrics": true, "food": true, "training": true, "journalAnswers": true, "journalNotes": true, "cycle": true],
                           forKey: AgentAccessPreferences.key)
        let preferences = AgentAccessPreferences(defaults: suite.defaults)
        for domain in [AgentDataDomain.metrics, .food, .training, .journalAnswers, .journalNotes, .cycle] { #expect(preferences.allows(domain), "\(domain)") }
        #expect(!preferences.allows(.supplements) && !preferences.allows(.labs))
        #expect(!AgentAccessPreferences.isAllowed(.supplements, defaults: suite.defaults) && !AgentAccessPreferences.isAllowed(.labs, defaults: suite.defaults))
        let gate = AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults)
        #expect(gate.blockedDomains == [.supplements, .labs])

        // Turning one on writes its key and leaves the rest as they were.
        preferences.set(.labs, allowed: true)
        let saved = suite.defaults.dictionary(forKey: AgentAccessPreferences.key) as? [String: Bool]
        #expect(saved?["labs"] == true && saved?["cycle"] == true && saved?["supplements"] == nil)
        let reopened = AgentAccessPreferences(defaults: suite.defaults)
        #expect(reopened.allows(.labs) && !reopened.allows(.supplements))
    }

    @Test func aReadOfTheTwoNewDomainsNeedsYourDataAndTheChat() throws {
        var chat = CoachSharing(metrics: false, journal: false, cycle: false, food: false, training: false)
        for (domain, keyPath) in [(AgentDataDomain.supplements, \CoachSharing.supplements), (.labs, \CoachSharing.labs)] as [(AgentDataDomain, WritableKeyPath<CoachSharing, Bool>)] {
            for (yourData, shared) in [(true, true), (true, false), (false, true), (false, false)] {
                let suite = AgentFixtures.Suite(); suite.setOnly(yourData ? [domain] : [])
                chat[keyPath: keyPath] = shared
                let gate = AgentAccessGate(consent: chat, defaults: suite.defaults)
                #expect(gate.isAllowed(domain) == (yourData && shared), "\(domain) with Your data \(yourData) and chat \(shared)")
                if yourData && !shared { #expect(throws: AgentAccessError.notShared(domain)) { try gate.check(domain) } }
                if !yourData { #expect(throws: AgentAccessError.off(domain)) { try gate.check(domain) } }
            }
            chat[keyPath: keyPath] = false
        }
        // The chat's switch for one domain leaves the other alone.
        let suite = AgentFixtures.Suite(); suite.setOnly([.supplements, .labs])
        var only = CoachSharing(metrics: false, journal: false, cycle: false, food: false, training: false)
        only.labs = true
        let gate = AgentAccessGate(consent: only, defaults: suite.defaults)
        #expect(gate.isAllowed(.labs) && !gate.isAllowed(.supplements))
        // Narrowing turns a chat's flag off when Your data is off, and never widens one.
        suite.set(.labs, false)
        let narrowed = AgentAccessGate.effective(AgentFixtures.everything, defaults: suite.defaults)
        #expect(narrowed.supplements && !narrowed.labs)
        #expect(!AgentAccessGate.effective(CoachSharing(), defaults: suite.defaults).supplements)
    }

    @Test func theTwoNewChatFlagsStartOffAndOldChatsReadThemAsNotShared() throws {
        #expect(!CoachSharing().supplements && !CoachSharing().labs)
        let old = try JSONDecoder().decode(CoachSharing.self, from: Data(#"{"metrics":true,"journal":true,"cycle":true,"food":true,"training":true,"journalAnswers":true,"journalNotes":true}"#.utf8))
        #expect(!old.supplements && !old.labs, "a chat saved before the two flags existed shares neither")
        let empty = try JSONDecoder().decode(CoachSharing.self, from: Data("{}".utf8))
        #expect(!empty.supplements && !empty.labs)
        let on = CoachSharing(supplements: true, labs: true)
        let again = try JSONDecoder().decode(CoachSharing.self, from: JSONEncoder().encode(on))
        #expect(again == on && again.supplements && again.labs)
        #expect(CoachSharing(supplements: true) != CoachSharing(labs: true))
        // A whole saved conversation without the fields decodes too.
        var conversation = CoachConversation(configuration: AgentFixtures.configuration())
        conversation.sharing = AgentFixtures.everything
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(conversation)) as? [String: Any])
        var sharing = try #require(json["sharing"] as? [String: Any])
        sharing.removeValue(forKey: "supplements"); sharing.removeValue(forKey: "labs")
        json["sharing"] = sharing
        let decoded = try JSONDecoder().decode(CoachConversation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.sharing.supplements && !decoded.sharing.labs && decoded.sharing.metrics)
    }

    @Test func yourDataListsEightSwitchesWithPlainOneLineDescriptions() {
        #expect(AgentDataDomain.allCases.map(\.rawValue) == ["metrics", "food", "training", "journalAnswers", "journalNotes", "cycle", "supplements", "labs"])
        // The screen builds each identifier from the raw value. The first six are the ones that shipped.
        #expect(AgentDataDomain.allCases.map { "agent-access-\($0.rawValue)" } == [
            "agent-access-metrics", "agent-access-food", "agent-access-training", "agent-access-journalAnswers", "agent-access-journalNotes",
            "agent-access-cycle", "agent-access-supplements", "agent-access-labs"])
        #expect(AgentDataDomain.supplements.title == "Supplements and medication" && AgentDataDomain.labs.title == "Blood tests")
        for domain in [AgentDataDomain.supplements, .labs] {
            let line = domain.detail ?? ""
            #expect(!line.isEmpty && line.count <= 60 && !line.contains("\n"), "\(domain): \(line)")
            for text in [domain.title, line] {
                #expect(!text.contains("!") && !text.contains("\u{2014}") && !text.contains("\u{2013}"), "\(text)")
            }
        }
        #expect(AgentDataDomain.food.detail == "Names and amounts, no photos" && AgentDataDomain.journalNotes.detail == "Your own words")
    }

    // MARK: Mid-chat

    private func makeRuntime(_ suite: AgentFixtures.Suite, transport: ScriptedAgentTransport) async throws -> (LooprAISettingsRuntime, CoachProviderConfiguration) {
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: NoStreamTransport(), agentTransport: transport)
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "test-key")
        return (runtime, try #require(try await runtime.selectedConfiguration()))
    }

    @Test(arguments: [AgentDataDomain.supplements, .labs, .journalAnswers, .training])
    func aSwitchFlippedMidChatIsEnforcedOnTheNextCallAndTheNextMessage(domain: AgentDataDomain) async throws {
        let tool: String = switch domain {
        case .supplements: AgentToolName.getSupplements
        case .labs: AgentToolName.getLabs
        case .journalAnswers: AgentToolName.getProtocol
        default: AgentToolName.getCapacity
        }
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let transport = ScriptedAgentTransport([.toolCalls([AgentFixtures.call(tool, id: "c1")]), .final("I could not read that."), .final("Second.")],
                                               onTurn: { index, _ in if index == 0 { suite.set(domain, false) } })
        let (runtime, configuration) = try await makeRuntime(suite, transport: transport)
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        let source = LongevityFakeSource()
        let mode = LooprAgentToolMode(runtime: runtime, source: source, writes: harness.writes, proposals: harness.center, defaults: suite.defaults,
                                      now: { AgentFixtures.now }, timeZone: { AgentFixtures.zone })
        var chat = AgentFixtures.conversation(); chat.configuration = configuration

        let output = try await mode.run(conversation: chat, assistantMessageID: UUID(), origin: nil)
        #expect(output.text == "I could not read that.")
        #expect(transport.requests[0].tools.contains { $0.name == tool }, "it was on when the request left")
        let outcome = try #require(transport.requests[1].rounds.first?.outcomes.first)
        #expect(outcome.denied)
        #expect(outcome.content == "\(domain.title) is off in Your data, so Ask did not read it.")
        #expect(source.count(domain.rawValue) == 0)

        _ = try await mode.run(conversation: chat, assistantMessageID: UUID(), origin: nil)
        #expect(!transport.requests[2].tools.contains { $0.name == tool }, "the next message no longer offers \(tool)")
        #expect(transport.requests[2].context.contains("Not available in this chat:") && transport.requests[2].context.contains(domain.title))
    }

    @Test func aSwitchTurnedOffWhileTheReadRunsDiscardsTheResult() async throws {
        struct Case { let tool: String; let flip: AgentDataDomain; let readerCounter: String; let secret: String }
        let cases = [
            Case(tool: AgentToolName.getProtocol, flip: .journalAnswers, readerCounter: "journalAnswers", secret: "Sleep first"),
            Case(tool: AgentToolName.getAdherence, flip: .journalAnswers, readerCounter: "journalAnswers", secret: "bed-before-2300"),
            Case(tool: AgentToolName.getSupplements, flip: .supplements, readerCounter: "supplements", secret: "Ramipril"),
            Case(tool: AgentToolName.getLabs, flip: .labs, readerCounter: "labs", secret: "Apolipoprotein B"),
            Case(tool: AgentToolName.getCapacity, flip: .training, readerCounter: "training", secret: "Grip"),
            // The result of an experiment needs sleep readings, and a weekly dose needs band minutes and Protocol targets.
            Case(tool: AgentToolName.getExperiments, flip: .metrics, readerCounter: "journalAnswers", secret: "Magnesium glycinate"),
            Case(tool: AgentToolName.getCapacity, flip: .metrics, readerCounter: "training", secret: "Grip"),
            Case(tool: AgentToolName.getCapacity, flip: .journalAnswers, readerCounter: "training", secret: "Grip"),
        ]
        for item in cases {
            let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
            let source = LongevityFakeSource()
            source.onRead = { name in if name == item.readerCounter { suite.set(item.flip, false) } }
            let outcome = await executor(AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: source)
                .execute(AgentFixtures.call(item.tool))
            #expect(outcome.denied, "\(item.tool) kept its result after \(item.flip.rawValue) went off")
            #expect(!outcome.content.contains(item.secret), "\(item.secret) reached the model")
            #expect(outcome.content == "\(item.flip.title) is off in Your data, so Ask did not read it.")
        }
    }

    // MARK: Writes

    @Test func everyWriteStillWaitsForAConfirmWithAllEightSwitchesOn() async throws {
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let chat = UUID(), message = UUID()
        let run = harness.executor(gate: AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: LongevityFakeSource(),
                                   conversationID: chat, messageID: message)
        for tool in Self.newTools { #expect(!(await run.execute(AgentFixtures.call(tool.name))).isError, "\(tool.name)") }
        let proposals: [(String, [String: Any])] = [
            (AgentToolName.proposeMeal, ["slot": "dinner", "day": "2026-10-15", "time": "19:30", "estimate": AgentFixtures.estimate()]),
            (AgentToolName.proposeJournalQuestion, ["name": "Late screens", "question": "Did you use screens in the hour before bed?"]),
            (AgentToolName.proposeReminder, ["title": "Wind down", "body": "Screens off.", "time": "20:15"]),
        ]
        var ids: [UUID] = []
        for (tool, arguments) in proposals {
            let outcome = await run.execute(AgentFixtures.call(tool, arguments))
            let json = try #require(JSONSerialization.jsonObject(with: Data(outcome.content.utf8)) as? [String: Any])
            #expect(json["status"] as? String == "awaiting_user_confirmation", "\(tool): \(outcome.content)")
            ids.append(try #require((json["proposalId"] as? String).flatMap(UUID.init(uuidString:))))
        }
        #expect(harness.writes.writeCount == 0 && harness.reminders.scheduled.isEmpty && harness.tests.started.isEmpty, "something was written before a tap")
        let waiting = await harness.center.proposals(conversationID: chat)
        #expect(waiting.count == 3 && waiting.allSatisfy { $0.state == .pending && $0.confirmedAt == nil && $0.appliedAt == nil })

        // A tap on one card saves that one and nothing else.
        let result = await harness.center.confirm(id: ids[0], at: AgentFixtures.now)
        #expect(result.applied)
        #expect(harness.writes.meals.count == 1 && harness.writes.habits.isEmpty && harness.reminders.scheduled.isEmpty)
    }

    @Test func theNewToolsOnlyReadAndNoWriteToolWasAdded() {
        let specs = AgentToolRegistry.specs(allowed: Set(AgentDataDomain.allCases), capabilities: .init(listsPatterns: true, startsTests: true))
        let byName = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0.domain) })
        for tool in Self.newTools {
            #expect(byName[tool.name] == tool.domain, "\(tool.name)")
            #expect(!tool.name.hasPrefix("propose_"))
        }
        #expect(Set(specs.map(\.name).filter { $0.hasPrefix("propose_") }) == [
            AgentToolName.proposeMeal, AgentToolName.proposeJournalQuestion, AgentToolName.proposeTemplateEdit,
            AgentToolName.proposeProgramDraft, AgentToolName.proposeReminder, AgentToolName.proposeTest])
        #expect(specs.count == 23)
    }

    @Test func eachNewToolIsAdvertisedOnlyWhileItsSwitchIsOn() {
        let all = Set(AgentDataDomain.allCases)
        func names(_ allowed: Set<AgentDataDomain>) -> Set<String> {
            Set(AgentToolRegistry.specs(allowed: allowed, capabilities: .init()).map(\.name))
        }
        #expect(names(all.subtracting([.supplements])).isDisjoint(with: [AgentToolName.getSupplements]) && names(all).contains(AgentToolName.getSupplements))
        #expect(names(all.subtracting([.labs])).isDisjoint(with: [AgentToolName.getLabs]) && names(all).contains(AgentToolName.getLabs))
        #expect(names(all.subtracting([.journalAnswers])).isDisjoint(with: [AgentToolName.getProtocol, AgentToolName.getAdherence, AgentToolName.getExperiments]))
        #expect(names(all.subtracting([.training])).isDisjoint(with: [AgentToolName.getCapacity]))
        // Ages stays while either switch behind it is on, and goes when both are off.
        #expect(names(all.subtracting([.metrics])).contains(AgentToolName.getAges) && names(all.subtracting([.labs])).contains(AgentToolName.getAges))
        #expect(!names(all.subtracting([.metrics, .labs])).contains(AgentToolName.getAges))
    }

    // MARK: The request log

    private static func toolUse(_ name: String) -> Data {
        Data(#"{"type":"message","role":"assistant","stop_reason":"tool_use","content":[{"type":"text","text":"Checking."},{"type":"tool_use","id":"toolu_1","name":"\#(name)","input":{}}]}"#.utf8)
    }
    private static func final(_ text: String) -> Data {
        Data(#"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"\#(text)"}]}"#.utf8)
    }
    private static func contains(_ object: Any, string: String) -> Bool {
        if let text = object as? String { return text.contains(string) }
        if let list = object as? [Any] { return list.contains { contains($0, string: string) } }
        if let map = object as? [String: Any] { return map.values.contains { contains($0, string: string) } }
        return false
    }

    @Test(arguments: [AgentToolName.getProtocol, AgentToolName.getAdherence, AgentToolName.getExperiments, AgentToolName.getSupplements,
                      AgentToolName.getLabs, AgentToolName.getCapacity, AgentToolName.getAges])
    func theLogHoldsTheExactBytesAndResultOfACallToEachNewTool(tool: String) async throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try SQLiteAgentRequestLog(database: database, now: { AgentFixtures.now })
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let stub = LongevityStubProtocol.state
        stub.script([(200, "application/json", Self.toolUse(tool)), (200, "application/json", Self.final("Done."))])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LongevityStubProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: CoachURLSessionTransport(session: session, recorder: log))
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "sk-test-secret")
        let providerConfiguration = try #require(try await runtime.selectedConfiguration())
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        let source = LongevityFakeSource()
        let mode = LooprAgentToolMode(runtime: runtime, source: source, writes: harness.writes, proposals: harness.center, defaults: suite.defaults,
                                      now: { AgentFixtures.now }, timeZone: { AgentFixtures.zone })
        var chat = AgentFixtures.conversation(); chat.configuration = providerConfiguration
        let output = try await mode.run(conversation: chat, assistantMessageID: UUID(), origin: nil)
        #expect(output.text == "Done.")

        let sent = stub.sent
        let logged = try log.records().reversed().map { $0 }
        #expect(sent.count == 2 && logged.count == 2)
        for (record, bytes) in zip(logged, sent) {
            #expect(record.body == bytes, "the log must hold the sent bytes, byte for byte")
            #expect(record.bodyBytes == bytes.count && record.status == .succeeded)
            #expect(!String(decoding: record.body, as: UTF8.self).contains("sk-test-secret"))
        }
        // The same call, run again on the same data, gives the result the second request carried.
        let expected = await executor(AgentAccessGate(consent: AgentFixtures.everything, defaults: suite.defaults), source: LongevityFakeSource())
            .execute(AgentFixtures.call(tool))
        #expect(!expected.isError)
        let body = try JSONSerialization.jsonObject(with: logged[1].body)
        #expect(Self.contains(body, string: expected.content), "the logged request holds the tool result exactly as sent")
        let domain = try #require(Self.newTools.first { $0.name == tool }?.domain)
        #expect(logged[1].toolCalls == [AIRecordedToolCall(name: tool, domain: domain, resultBytes: expected.contentBytes, isError: false, denied: false)])
        #expect(logged[1].denials.isEmpty)
        #expect(String(decoding: logged[0].body, as: UTF8.self).contains("\"\(tool)\""), "the first request lists the tool")
    }

    @Test func aRefusedLookupIsLoggedWithOnlyTheFactThatItIsOff() async throws {
        let (database, root) = try AgentFixtures.temporaryDatabase(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try SQLiteAgentRequestLog(database: database, now: { AgentFixtures.now })
        let suite = AgentFixtures.Suite(); suite.setOnly(Set(AgentDataDomain.allCases))
        let stub = LongevityStubProtocol.state
        stub.script([(200, "application/json", Self.toolUse(AgentToolName.getLabs)), (200, "application/json", Self.final("Blood tests are off."))])
        stub.onRequest = { index in if index == 0 { suite.set(.labs, false) } }   // flipped after the tool was advertised
        defer { stub.onRequest = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LongevityStubProtocol.self]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let runtime = LooprAISettingsRuntime(defaults: suite.defaults, credentials: AgentTestCredentials(), transport: CoachURLSessionTransport(session: session, recorder: log))
        try await runtime.configure(provider: .anthropic, model: "claude-haiku-5-5", apiKey: "sk-test-secret")
        let providerConfiguration = try #require(try await runtime.selectedConfiguration())
        let harness = try ProposalHarness.make(); defer { harness.cleanup() }
        let source = LongevityFakeSource()
        let mode = LooprAgentToolMode(runtime: runtime, source: source, writes: harness.writes, proposals: harness.center, defaults: suite.defaults,
                                      now: { AgentFixtures.now }, timeZone: { AgentFixtures.zone })
        var chat = AgentFixtures.conversation(); chat.configuration = providerConfiguration
        _ = try await mode.run(conversation: chat, assistantMessageID: UUID(), origin: nil)

        let logged = try log.records().reversed().map { $0 }
        #expect(logged.count == 2 && logged.map(\.body) == stub.sent)
        let message = "Blood tests is off in Your data, so Ask did not read it."
        #expect(logged[1].toolCalls == [AIRecordedToolCall(name: AgentToolName.getLabs, domain: "labs", resultBytes: message.utf8.count, isError: true, denied: true)])
        #expect(logged[1].denials == [AIRecordedDenial(toolName: AgentToolName.getLabs, domain: "labs", message: message)])
        #expect(String(decoding: logged[1].body, as: UTF8.self).contains(message))
        #expect(!String(decoding: logged[1].body, as: UTF8.self).contains("Apolipoprotein B"), "no blood test value went out")
        #expect(source.count("labs") == 0)
    }
}
