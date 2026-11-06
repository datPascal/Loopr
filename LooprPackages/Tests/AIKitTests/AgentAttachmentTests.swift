import Foundation
import Testing
@testable import AIKit

/// The attachments a reply keeps: sources, charts and card ids. They are saved with the chat, so old
/// chats must decode and a newer build's unknown attachment must not take the chat down with it.
struct AgentAttachmentTests {
    private let chart = AgentChartSnapshot(id: "food.energy.2026-10-10.2026-10-16", title: "Energy per day", unit: "kcal", domain: .food,
                                           points: [AgentChartPoint(day: "2026-10-14", value: 2100), AgentChartPoint(day: "2026-10-15", value: 820)],
                                           kind: .bars, highlightedDays: ["2026-10-15"], caption: "Brighter bars had dinner after 21:00")
    private let source = AgentSource(id: "food.2026-10-10.2026-10-16", domain: .food, label: "Food log", count: 2,
                                     range: AgentDayRange(from: "2026-10-14", to: "2026-10-15"), recordIDs: ["meal-1"], link: .foodDay(day: "2026-10-15"))

    private func message(_ attachments: [AgentAttachment]) -> CoachChatMessage {
        CoachChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, role: .assistant, text: "Answer.",
                         createdAt: Date(timeIntervalSinceReferenceDate: 782_000_000), attachments: attachments)
    }

    @Test func attachmentsRoundTrip() throws {
        let original = message([.chart(chart), .sources([source]), .proposal(UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!)])
        #expect(try JSONDecoder().decode(CoachChatMessage.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test func aMessageSavedBeforeAttachmentsDecodesWithNone() throws {
        let old = #"{"id":"00000000-0000-0000-0000-0000000000D1","role":"assistant","text":"Hi","status":"complete","createdAt":782000000}"#
        let decoded = try JSONDecoder().decode(CoachChatMessage.self, from: Data(old.utf8))
        #expect(decoded.attachments.isEmpty && decoded.text == "Hi" && decoded.journalEntryID == nil && decoded.stopReason == nil)
    }

    @Test func anEmptyListWritesNoKey() throws {
        let keys = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message([]))) as? [String: Any]).keys
        #expect(!keys.contains("attachments"))
    }

    @Test func anUnknownAttachmentIsDroppedNotFatal() throws {
        var root = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message([.sources([source])]))) as? [String: Any])
        var list = try #require(root["attachments"] as? [[String: Any]])
        list.append(["kind": "hologram"])
        root["attachments"] = list
        let decoded = try JSONDecoder().decode(CoachChatMessage.self, from: JSONSerialization.data(withJSONObject: root))
        #expect(decoded.attachments == [.sources([source])])
    }

    @Test func aChartWithoutTheNewerFieldsDecodesWithDefaults() throws {
        let json = #"{"id":"c","title":"Steps","unit":"steps","domain":"metrics","points":[]}"#
        let decoded = try JSONDecoder().decode(AgentChartSnapshot.self, from: Data(json.utf8))
        #expect(decoded.kind == .bars && decoded.highlightedDays.isEmpty && decoded.caption == nil)
    }
}
