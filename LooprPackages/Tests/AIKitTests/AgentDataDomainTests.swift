import AIKit
import Foundation
import Testing

/// The domain names are stored in Your data, in saved chats and in the request log, so they must not change.
struct AgentDataDomainTests {
    @Test func theEightDomainsKeepTheirStoredNamesInDisplayOrder() {
        #expect(AgentDataDomain.allCases.map(\.rawValue) == ["metrics", "food", "training", "journalAnswers", "journalNotes", "cycle", "supplements", "labs"])
    }

    @Test func aSavedSourceWithANewDomainRoundTrips() throws {
        for domain in [AgentDataDomain.supplements, .labs] {
            let source = AgentSource(id: "x", domain: domain, label: "Blood tests", count: 1, range: nil, recordIDs: ["r"], link: nil)
            let data = try JSONEncoder().encode(AgentAttachment.sources([source]))
            #expect(try JSONDecoder().decode(AgentAttachment.self, from: data) == .sources([source]))
        }
    }

    @Test func aSourceFromBuild21StillDecodes() throws {
        let json = #"{"kind":"sources","sources":[{"id":"food.1","domain":"food","label":"Food log","count":2,"recordIDs":["a","b"]}]}"#
        guard case .sources(let sources) = try JSONDecoder().decode(AgentAttachment.self, from: Data(json.utf8)) else {
            Issue.record("not a sources attachment"); return
        }
        #expect(sources.first?.domain == .food && sources.first?.count == 2)
    }
}
