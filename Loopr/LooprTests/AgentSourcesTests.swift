import AIKit
import DomainKit
import Foundation
import Testing
@testable import Loopr

/// FT-05.3: the source strip under an answer. Sources come from records a tool returned, they are saved
/// with the reply, and a source button maps to a real screen.
@MainActor
@Suite(.serialized)
struct AgentSourcesTests {
    // MARK: Built from returned records only

    @Test func sourcesCoverWhatToolsReturnedAndNothingElse() async throws {
        let calls = [
            AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd", "steps"], "from": "2026-09-01", "to": "2026-10-14"], id: "c1"),
            AgentFixtures.call(AgentToolName.getFood, ["from": "2026-10-10", "to": "2026-10-16"], id: "c2"),
            AgentFixtures.call(AgentToolName.getTraining, ["from": "2026-10-10", "to": "2026-10-16"], id: "c3"),
            AgentFixtures.call(AgentToolName.getJournal, ["from": "2026-10-12", "to": "2026-10-12"], id: "c4"),
        ]
        // The model's own text claims it read 90 days of everything. The strip must not repeat that.
        let rig = try await AttachmentRig.make([.toolCalls(calls), .final("I read 90 days of sleep, food, cycle and journal notes.")])
        defer { rig.cleanup() }
        await rig.ask("Why did I sleep badly?")
        let sources = try #require(rig.reply).attachedSources

        let metrics = try #require(sources.first { $0.domain == .metrics })
        #expect(metrics.count == 14, "the request asked for 44 days, the app returned 14")
        #expect(metrics.range == AgentDayRange(from: "2026-10-01", to: "2026-10-14"))
        #expect(metrics.recordIDs == (1...14).map { String(format: "rmssd:2026-10-%02d", $0) })
        #expect(metrics.link == .metric(key: "rmssd", day: "2026-10-14"))
        #expect(sources.count == 3, "steps had no readings and the journal day had no answers, so neither is a source")
        #expect(Set(sources.map(\.domain)) == [.metrics, .food, .training])
        let food = try #require(sources.first { $0.domain == .food })
        #expect(food.count == 2 && food.recordIDs == ["meal-1"], "the meal ids the read returned")
        #expect(food.link == .foodDay(day: "2026-10-15"))
        #expect(try #require(sources.first { $0.domain == .training }).link == .trainSession(id: "session-1"))
    }

    @Test func aDomainThatIsOffLeavesNoSource() async throws {
        let rig = try await AttachmentRig.make([
            .toolCalls([AgentFixtures.call(AgentToolName.getFood, ["from": "2026-10-10", "to": "2026-10-16"], id: "c1")]),
            .final("I could not read your food log.")])
        defer { rig.cleanup() }
        rig.suite.set(.food, false)
        await rig.ask("What did I eat?")
        #expect(try #require(rig.reply).attachedSources.isEmpty)
        #expect(rig.source.count("food") == 0, "the gate stopped the read")
    }

    @Test func anAnswerWithNoReadsHasNoAttachments() async throws {
        let rig = try await AttachmentRig.make([.final("Sleep is about more than the last night.")])
        defer { rig.cleanup() }
        await rig.ask("Any tips?")
        #expect(try #require(rig.reply).attachments.isEmpty)
    }

    // MARK: Saved with the reply

    @Test func attachmentsAreSavedWithTheReplyAndSurviveARelaunch() async throws {
        let meal = AgentFixtures.call(AgentToolName.proposeMeal, ["slot": "dinner", "day": "2026-10-15", "time": "21:30", "estimate": AgentFixtures.estimate()], id: "p1")
        let reads = [AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-01", "to": "2026-10-14"], id: "c1"),
                     AgentFixtures.call(AgentToolName.showChart, ["chartId": "metric.rmssd.2026-10-01.2026-10-14"], id: "c2"), meal]
        let rig = try await AttachmentRig.make([.toolCalls(reads), .final("Heart rate variability held steady. I prepared the dinner.")])
        defer { rig.cleanup() }
        await rig.ask("Log my dinner and check HRV")
        let reply = try #require(rig.reply)
        #expect(reply.chartSnapshots.count == 1 && reply.attachedSources.count == 1 && reply.proposalIDs.count == 1)
        // Charts, then the source strip, then the cards, the order the row shows them in.
        guard case .chart = reply.attachments[0], case .sources = reply.attachments[1], case .proposal = reply.attachments[2] else {
            Issue.record("unexpected attachment order: \(reply.attachments)"); return
        }

        let next = try await rig.relaunched()
        let restored = try #require(next.conversation?.messages.last)
        #expect(restored.attachments == reply.attachments)
        let card = try #require(next.agentProposals[restored.id]?.first)
        #expect(card.id == restored.proposalIDs.first && card.state == .pending)
    }

    @Test func aConfirmedCardStaysConfirmedAfterARelaunch() async throws {
        let meal = AgentFixtures.call(AgentToolName.proposeMeal, ["slot": "dinner", "day": "2026-10-15", "time": "21:30", "estimate": AgentFixtures.estimate()], id: "p1")
        let rig = try await AttachmentRig.make([.toolCalls([meal]), .final("Prepared.")])
        defer { rig.cleanup() }
        await rig.ask("Log my dinner")
        let id = try #require(rig.reply?.proposalIDs.first)
        await rig.model.confirmProposal(id)
        #expect(rig.harness.writes.meals.count == 1)

        let next = try await rig.relaunched()
        let replyID = try #require(next.conversation?.messages.last?.id)
        #expect(next.agentProposals[replyID]?.first?.state == .applied)
        await next.confirmProposal(id)
        #expect(rig.harness.writes.meals.count == 1, "the card does not save a second time")
    }

    @Test func deletingTheChatDeletesItsAttachmentsAndCards() async throws {
        let meal = AgentFixtures.call(AgentToolName.proposeMeal, ["slot": "dinner", "day": "2026-10-15", "time": "21:30", "estimate": AgentFixtures.estimate()], id: "p1")
        let read = AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-01", "to": "2026-10-14"], id: "c1")
        let rig = try await AttachmentRig.make([.toolCalls([read, meal]), .final("Done.")])
        defer { rig.cleanup() }
        await rig.ask("Check HRV and log dinner")
        let chat = try #require(rig.model.conversation)
        #expect(chat.messages.last?.attachments.isEmpty == false)
        #expect(await rig.harness.center.proposals(conversationID: chat.id).count == 1)

        await rig.model.delete(chat)
        #expect(await rig.repository.rows[chat.id] == nil, "the chat file, and the attachments inside it, are gone")
        #expect(await rig.harness.center.proposals(conversationID: chat.id).isEmpty)
        #expect(rig.model.agentProposals.isEmpty)
    }

    // MARK: Coding

    private func message(attachments: [AgentAttachment]) -> CoachChatMessage {
        CoachChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, role: .assistant, text: "Answer.",
                         createdAt: Date(timeIntervalSinceReferenceDate: 782_000_000), attachments: attachments)
    }
    private let source = AgentSource(id: "food.2026-10-10.2026-10-16", domain: .food, label: "Food log", count: 5,
                                     range: AgentDayRange(from: "2026-10-10", to: "2026-10-15"), recordIDs: ["meal-1"], link: .foodDay(day: "2026-10-15"))
    private let chart = AgentChartSnapshot(id: "metric.rmssd.2026-10-01.2026-10-03", title: "Heart rate variability", unit: "ms", domain: .metrics,
                                           points: [AgentChartPoint(day: "2026-10-01", value: 51), AgentChartPoint(day: "2026-10-03", value: 53)],
                                           kind: .line, highlightedDays: ["2026-10-03"], caption: "Brighter days followed a late dinner")

    @Test func everyAttachmentCaseRoundTrips() throws {
        let links: [AgentSourceLink] = [.metric(key: "rmssd", day: "2026-10-14"), .sleep(day: "2026-10-14"), .foodDay(day: "2026-10-15"),
                                        .workout(id: "w1"), .trainSession(id: "s1"), .habitCheckIn(day: "2026-10-15"), .habitHistory, .patterns]
        let sources = links.enumerated().map { index, link in
            AgentSource(id: "s\(index)", domain: .metrics, label: "Label \(index)", count: index, range: nil, recordIDs: ["r\(index)"], link: link)
        } + [AgentSource(id: "none", domain: .cycle, label: "Cycle records", count: 2, range: nil, recordIDs: [], link: nil)]
        let original = message(attachments: [.chart(chart), .sources(sources), .proposal(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!)])
        let decoded = try JSONDecoder().decode(CoachChatMessage.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.chartSnapshots.first?.highlightedDays == ["2026-10-03"] && decoded.chartSnapshots.first?.kind == .line)
    }

    @Test func attachmentsSurviveTheRealChatStore() async throws {
        let (database, root) = try AgentFixtures.temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        var chat = CoachConversation(configuration: AgentFixtures.configuration(), now: AgentFixtures.now)
        chat.messages = [CoachChatMessage(role: .user, text: "Why?"), message(attachments: [.chart(chart), .sources([source])])]
        try await SQLiteCoachConversationRepository(database: database).save(chat)
        let reopened = try await SQLiteCoachConversationRepository(database: database).conversations()
        #expect(reopened.first?.messages.last?.attachments == [.chart(chart), .sources([source])])
    }

    @Test func chatsSavedBeforeAttachmentsExistedStillDecode() throws {
        var chat = CoachConversation(configuration: AgentFixtures.configuration(), now: AgentFixtures.now)
        chat.messages = [CoachChatMessage(role: .user, text: "Why?"), message(attachments: [.sources([source])])]
        // Write the chat the way the previous build did: the same keys, no `attachments`.
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as? [String: Any])
        var messages = try #require(root["messages"] as? [[String: Any]])
        for index in messages.indices { messages[index].removeValue(forKey: "attachments") }
        root["messages"] = messages
        let old = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(CoachConversation.self, from: old)
        #expect(decoded.messages.map(\.text) == ["Why?", "Answer."])
        #expect(decoded.messages.allSatisfy { $0.attachments.isEmpty })
    }

    @Test func aMessageWithoutAttachmentsWritesTheSameKeysAsBefore() throws {
        let data = try JSONEncoder().encode(CoachChatMessage(role: .user, text: "Hello"))
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(!keys.contains("attachments"), "an older build reads this file without meeting a key it does not know")
    }

    @Test func anAttachmentFromANewerBuildIsDroppedAndTheChatStaysReadable() throws {
        let original = message(attachments: [.chart(chart), .sources([source])])
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var list = try #require(root["attachments"] as? [[String: Any]])
        list.insert(["kind": "hologram", "hologram": ["depth": 3]], at: 1)
        list.append(["kind": "sources", "sources": [["id": "x", "domain": "teleportation", "label": "?", "count": 1, "recordIDs": []]]])
        root["attachments"] = list
        let decoded = try JSONDecoder().decode(CoachChatMessage.self, from: JSONSerialization.data(withJSONObject: root))
        #expect(decoded.text == "Answer.")
        #expect(decoded.attachments == [.chart(chart), .sources([source])])
    }

    @Test func aChartSavedWithoutTheNewerFieldsDecodesWithDefaults() throws {
        let json = #"{"id":"metric.steps.a.b","title":"Steps","unit":"steps","domain":"metrics","points":[{"day":"2026-10-14","value":8000}]}"#
        let decoded = try JSONDecoder().decode(AgentChartSnapshot.self, from: Data(json.utf8))
        #expect(decoded.kind == .bars && decoded.highlightedDays.isEmpty && decoded.caption == nil)
    }

    @Test func attachmentsNeverTravelToTheProvider() async throws {
        let read = AgentFixtures.call(AgentToolName.getMetrics, ["metrics": ["rmssd"], "from": "2026-10-01", "to": "2026-10-14"], id: "c1")
        let rig = try await AttachmentRig.make([.toolCalls([read]), .final("Steady."), .final("Second answer.")])
        defer { rig.cleanup() }
        await rig.ask("Check HRV")
        await rig.ask("And now?")
        let request = try #require(rig.transport.requests.last)
        let body = String(decoding: try request.payload(), as: UTF8.self)
        #expect(!body.contains("recordIDs") && !body.contains("rmssd:2026-10-01") && !body.contains("highlightedDays"))
    }

    // MARK: Source buttons

    @Test func everySourceLinkMapsToAScreen() {
        let day = DayIdentity(year: 2026, month: 10, day: 14)
        let workout = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
        #expect(AgentSourceDestination(.metric(key: "rmssd", day: "2026-10-14")) == .metric(.rmssd, day: day))
        #expect(AgentSourceDestination(.sleep(day: "2026-10-14")) == .sleepNight(day: day))
        #expect(AgentSourceDestination(.foodDay(day: "2026-10-14")) == .foodDay(day: day))
        #expect(AgentSourceDestination(.workout(id: workout.uuidString)) == .workout(workout))
        #expect(AgentSourceDestination(.trainSession(id: workout.uuidString)) == .trainSession(workout))
        #expect(AgentSourceDestination(.habitCheckIn(day: "2026-10-14")) == .habitCheckIn("2026-10-14"))
        #expect(AgentSourceDestination(.habitHistory) == .habitHistory)
        #expect(AgentSourceDestination(.patterns) == .patterns)
    }

    @Test func aSourceThatCannotBeReadLandsOnItsTabNotOnABlankScreen() {
        #expect(AgentSourceDestination(.metric(key: "not_a_metric", day: "2026-10-14")) == .tabHome(.data))
        #expect(AgentSourceDestination(.workout(id: "session-1")) == .tabHome(.fitness))
        #expect(AgentSourceDestination(.trainSession(id: "")) == .tabHome(.fitness))
        #expect(AgentSourceDestination(.habitCheckIn(day: "2026-02-31")) == .tabHome(.protocol))
        // A bad day still opens the right screen, on the day it already shows.
        #expect(AgentSourceDestination(.sleep(day: "yesterday")) == .sleepNight(day: nil))
    }

    @Test func theShellDeepLinkCarriesTheSourceThrough() {
        #expect(ShellDeepLink.agentSource(.patterns) == .agentSource(.patterns))
        #expect(ShellDeepLink.agentSource(.patterns) != .agentSource(.habitHistory))
    }

    @Test func sourceButtonsNameWhatWasReadAndHowMuch() {
        func source(_ domain: AgentDataDomain, _ label: String, _ count: Int, id: String = "id", link: AgentSourceLink? = nil) -> AgentSource {
            AgentSource(id: id, domain: domain, label: label, count: count, range: nil, recordIDs: [], link: link)
        }
        #expect(AgentSourceCopy.text(source(.food, "Food log", 5)) == "Food log · 5 days")
        #expect(AgentSourceCopy.text(source(.food, "Food log", 1)) == "Food log · 1 day")
        #expect(AgentSourceCopy.text(source(.metrics, "Sleep duration", 14, link: .sleep(day: "2026-10-14"))) == "Sleep duration · 14 nights")
        #expect(AgentSourceCopy.text(source(.training, "Training", 3)) == "Training · 3 workouts")
        #expect(AgentSourceCopy.text(source(.journalNotes, "Journal notes", 1)) == "Journal notes · 1 note")
        #expect(AgentSourceCopy.text(source(.cycle, "Cycle records", 2)) == "Cycle records · 2 records")
        #expect(AgentSourceCopy.text(source(.metrics, "Patterns", 3, id: "patterns", link: .patterns)) == "Patterns · 3 patterns")
        #expect(AgentSourceCopy.spoken(source(.food, "Food log", 5)) == "Food log, 5 days")
    }
}
