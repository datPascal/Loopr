import Testing
@testable import DesignSystem

@MainActor struct AssociationRowTests {
    @Test func voiceOverKeepsUnitsUncertaintyAndSampleCountWithoutCausalLanguage() {
        let row = LooprAssociationRow(title: "Alcohol", detail: "8 ms lower after days you answered Yes.",
            evidence: "No clear association · 32 nights", share: -0.8, accent: .heart,
            identifier: "association-test") {}
        #expect(row.accessibilitySummary == "Alcohol. 8 ms lower after days you answered Yes. No clear association · 32 nights")
        #expect(!row.accessibilitySummary.contains("lowers the score"))
    }
}
