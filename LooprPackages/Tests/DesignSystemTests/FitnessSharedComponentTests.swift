import SwiftUI
import Testing
@testable import DesignSystem

/// The two shared pieces LV-06.2 added for the Fitness tab: the barbell's target outlines and the
/// scaffold's colour field.
struct FitnessSharedComponentTests {
    /// Two sessions done of three: two loaded pairs, then one outlined pair past them.
    @Test func outlinesFollowTheLoadedPlates() {
        let slots = LooprBarbellGraphic.slots(plates: [20, 20], outlines: 1, outlineWeight: 20)
        #expect(slots.map(\.id) == ["0-20.0", "1-20.0", "outline-2"])
        #expect(slots.map(\.isOutline) == [false, false, true])
    }

    /// When the third session lands its outline leaves and a plate takes its place. The two loaded
    /// plates keep their identity, so only the new one slides on.
    @Test func loadingAnOutlineKeepsTheOtherPlatesInPlace() {
        let before = LooprBarbellGraphic.slots(plates: [20, 20], outlines: 1, outlineWeight: 20).map(\.id)
        let after = LooprBarbellGraphic.slots(plates: [20, 20, 20], outlines: 0, outlineWeight: 20).map(\.id)
        #expect(Array(after.prefix(2)) == Array(before.prefix(2)))
        #expect(after.last == "2-20.0")
        #expect(!after.contains("outline-2"))
    }

    @Test func aNegativeOutlineCountDrawsNoOutline() {
        #expect(LooprBarbellGraphic.slots(plates: [20], outlines: -2, outlineWeight: 20).count == 1)
        #expect(LooprBarbellGraphic.slots(plates: [], outlines: 3, outlineWeight: 20).allSatisfy { $0.isOutline })
    }

    @MainActor
    @Test func theScaffoldDrawsTheGlowUnlessAFieldIsGiven() {
        let header = LooprTabHeaderContent(title: "Fitness", accent: .strain)
        let glow = LooprTabScaffold(header: header, glow: .strain, identifier: "glow") { EmptyView() }
        let field = LooprTabScaffold(header: header, glow: .strain, field: .fitness, identifier: "field") { EmptyView() }
        #expect(glow.field == nil)
        #expect(field.field == .fitness)
        #expect(LooprColorFieldTab.fitness.accent == .strain)
    }

    /// LV-07.1: the Protocol tab sits on its own field, led by the plum accent.
    @MainActor
    @Test func theProtocolTabUsesItsOwnField() {
        let header = LooprTabHeaderContent(title: "Protocol", accent: .protocol)
        let scaffold = LooprTabScaffold(header: header, glow: .protocol, field: .protocol, identifier: "journal-screen") { EmptyView() }
        #expect(scaffold.field == .protocol)
        #expect(LooprColorFieldPalette.tab(.protocol).accent == .protocol)
        #expect(LooprColorFieldTab.protocol.accent == .protocol)
    }
}
