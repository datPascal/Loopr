import Testing
@testable import DesignSystem

/// The barbell on the set screen: plate colours and plate identity, which decides what animates.
struct BarbellGraphicTests {
    @Test func platesFollowTheCompetitionColours() {
        #expect(LooprPlateColor.token(25) == .heart)
        #expect(LooprPlateColor.token(20) == .sleep)
        #expect(LooprPlateColor.token(15) == .energy)
        #expect(LooprPlateColor.token(10) == .recoveryHigh)
        #expect(LooprPlateColor.token(5) == .ink)
        #expect(LooprPlateColor.token(2.5) == .strain)
        #expect(LooprPlateColor.token(1.25) == .inkMuted)
    }

    /// Adding 2.5 kg to 85 kg keeps the 25 and the 5 and adds one plate, so only that plate slides on.
    @Test func aPlateKeepsItsIdentityWhileThePlatesInsideItStay() {
        func ids(_ total: Double) -> [String] {
            LooprPlateMath.perSide(total: total).plates.enumerated()
                .map { LooprBarbellGraphic.Slot(index: $0.offset, weight: $0.element).id }
        }
        let before = ids(85), after = ids(87.5)
        #expect(before == ["0-25.0", "1-5.0", "2-2.5"])
        #expect(Array(after.prefix(3)) == before)
        #expect(after.count == 4)
        // 90 kg is 25 + 10: the 5 and 2.5 leave, a 10 arrives, the 25 stays put.
        #expect(ids(90) == ["0-25.0", "1-10.0"])
    }

    @Test func heavierPlatesAreTallerAndThicker() {
        let order = LooprPlateMath.plates
        for (heavier, lighter) in zip(order, order.dropFirst()) {
            #expect(LooprBarbellGraphic.heightShare(heavier) >= LooprBarbellGraphic.heightShare(lighter))
            #expect(LooprBarbellGraphic.thickness(heavier) > LooprBarbellGraphic.thickness(lighter))
        }
    }
}
