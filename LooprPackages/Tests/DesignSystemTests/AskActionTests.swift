import Testing
@testable import DesignSystem

@MainActor
struct AskActionTests {
    @Test func headerKeepsExistingIdentifierAndPassesItsOrigin() {
        var origin: String?
        let action = LooprAskAction { origin = $0 }
        let header = action.header(for: "Today", identifier: "today-header-coach")
        #expect(header.identifier == "today-header-coach")
        #expect(header.symbol == "sparkles")
        header.run()
        #expect(origin == "Today")
        #expect(action.header(for: "Health").identifier == "health-header-ask")
        // Tab headers say "Ask" beside the sparkle (R1-NEW-17); the pushed-page toolbar keeps the symbol alone.
        #expect(header.title == "Ask")
        #expect(action.header(for: "Sleep", titled: false).title == nil)
    }

    @Test func promptReachesTheShellOnlyWhenItAcceptsOne() {
        var opened: [String] = []
        let plain = LooprAskAction { opened.append("plain:" + $0) }
        plain.open("Sleep", prompt: "What was different about this night?")
        plain.open("Food")
        let prompted = LooprAskAction(run: { opened.append("run:" + $0) }, runWithPrompt: { opened.append("prompt:\($0):\($1)") })
        prompted.open("Sleep", prompt: "What was different about this night?")
        prompted.open("Sleep")
        #expect(opened == ["plain:Sleep", "plain:Food", "prompt:Sleep:What was different about this night?", "run:Sleep"])
    }
}
