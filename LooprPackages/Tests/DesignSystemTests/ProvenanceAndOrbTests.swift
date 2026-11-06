import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

/// LV-01.4: every provenance case has its words, its spoken label and its dot; a chip with an action
/// has a 44 pt hit area; the coach orb follows the colour field's rules.
@MainActor struct ProvenanceChipTests {
    @Test func everyCaseHasItsLabelAndSpokenSource() {
        let cases: [(LooprProvenance, String?, String)] = [
            (.band(device: "Band 4.0"), "Band 4.0", "From Band 4.0"),
            (.band(device: " "), "Band", "From the band"),
            (.appleHealth(source: "Apple Watch"), "Apple Watch", "From Apple Watch through Apple Health"),
            (.appleHealth(source: ""), "Apple Health", "From Apple Health"),
            (.appleHealth(source: "Health", typedIn: true), "Typed into Apple Health", "From Apple Health, typed in"),
            (.food(.logged), "Food log", "From your food log"),
            (.food(.barcode), "Open Food Facts", "From Open Food Facts"),
            (.food(.photoEstimate), "Photo estimate", "From a photo estimate"),
            (.lab(name: "City Lab"), "City Lab", "From City Lab"),
            (.lab(name: ""), "Lab report", "From a lab report"),
            (.typedIn, "Typed in", "From what you typed in"),
            (.estimated(method: "PhenoAge"), "PhenoAge estimate", "From a PhenoAge estimate"),
            (.estimated(method: ""), "Loopr estimate", "From a Loopr estimate"),
            (.onThisPhone, "On this iPhone", "From this iPhone"),
            (.absent, nil, "Not measured")
        ]
        for (provenance, label, spoken) in cases {
            #expect(provenance.label == label, "\(provenance)")
            #expect(provenance.accessibilityLabel() == spoken, "\(provenance)")
            if let label {
                #expect(!label.contains("\u{2014}") && !label.contains("!"))
                #expect(label.first?.isUppercase == true, "sentence case: \(label)")
            }
        }
    }

    @Test func qualifierJoinsTheTextAndTheSpokenLabel() {
        let provenance = LooprProvenance.appleHealth(source: "Apple Watch")
        #expect(provenance.text(qualifier: "42-day median") == "Apple Watch · 42-day median")
        #expect(provenance.accessibilityLabel(qualifier: "42-day median") == "From Apple Watch through Apple Health, 42-day median")
        #expect(LooprProvenance.onThisPhone.accessibilityLabel(qualifier: "2 min ago") == "From this iPhone, 2 min ago")
        #expect(LooprProvenance.onThisPhone.text(qualifier: "  ") == "On this iPhone")
        #expect(LooprProvenance.absent.text(qualifier: "today") == nil)
    }

    @Test func compactShowsTheSourceOnlyAndKeepsTheQualifierForVoiceOver() {
        let compact = ProvenanceChip(.band(device: ""), qualifier: "last night", style: .compact)
        #expect(compact.displayedText == "Band")
        #expect(compact.accessibilityText == "From the band, last night")
        #expect(ProvenanceChip(.band(device: ""), qualifier: "last night").displayedText == "Band · last night")
        #expect(ProvenanceChip(.onThisPhone, qualifier: "30 nights", style: .compact).displayedText == "iPhone")
        #expect(ProvenanceChip(.absent, style: .compact).displayedText == nil)
    }

    @Test func everySourceHasADotColour() {
        #expect(LooprProvenance.band(device: "Band").tint == .brand)
        #expect(LooprProvenance.appleHealth(source: "Apple Watch").tint == .heart)
        #expect(LooprProvenance.food(.barcode).tint == .energy)
        #expect(LooprProvenance.lab(name: "Lab").tint == .sleep)
        #expect(LooprProvenance.onThisPhone.tint == .brand)
        #expect(LooprProvenance.typedIn.tint == .inkSecondary)
    }

    @Test func absentShowsNothingOrNotMeasuredAsTheCallerAsks() {
        #expect(ProvenanceChip(.absent).displayedText == nil)
        #expect(ProvenanceChip(.absent, absent: .notMeasured).displayedText == "Not measured")
        #expect(!ProvenanceChip(.absent) {}.isInteractive)
        #expect(ProvenanceChip(.absent, absent: .notMeasured).accessibilityText == "Not measured")
    }

    @Test func chipWithAnActionHasA44PointHitArea() {
        let tappable = ProvenanceChip(.onThisPhone, identifier: "chip") {}
        #expect(tappable.isInteractive)
        #expect(tappable.hitHeight == 44)
        let plain = ProvenanceChip(.onThisPhone, identifier: "chip")
        #expect(!plain.isInteractive)
        #expect(plain.hitHeight == nil)

        let tappableHost = UIHostingController(rootView: tappable)
        #expect(tappableHost.sizeThatFits(in: CGSize(width: 393, height: 200)).height >= 44)
        let plainHost = UIHostingController(rootView: plain)
        #expect(plainHost.sizeThatFits(in: CGSize(width: 393, height: 200)).height < 44)
    }

    @Test func craftDetailGalleryLaysOut() {
        #expect(LooprCraftDetailGallery.chips.count == 11)
        #expect(Set(LooprCraftDetailGallery.chips.map(\.id)).count == 11)
        let host = UIHostingController(rootView: ScrollView { LooprCraftDetailGallery().padding(20) }
            .environment(\.looprEntranceStore, LooprEntranceStore(defaults: UserDefaults(suiteName: "gallery-\(UUID())")!, arguments: [])))
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.layoutIfNeeded()
        _ = DesignSystemGallery(initialSection: "craft")
    }
}

@MainActor struct LooprCoachOrbTests {
    private static func policy(visible: Bool = true, lowPower: Bool = false, reduceMotion: Bool = false,
                               reduceTransparency: Bool = false, increasedContrast: Bool = false) -> LooprColorFieldPolicy {
        LooprColorFieldPolicy(isVisible: visible, isLowPowerModeEnabled: lowPower, reduceMotion: reduceMotion,
                              reduceTransparency: reduceTransparency, increasedContrast: increasedContrast)
    }

    @Test func orbTurnsOnlyWhenTheFieldWouldDrift() {
        #expect(LooprCoachOrb.Appearance(Self.policy()) == .turning)
        #expect(LooprCoachOrb.Appearance(Self.policy(visible: false)) == .still)
        #expect(LooprCoachOrb.Appearance(Self.policy(lowPower: true)) == .still)
        #expect(LooprCoachOrb.Appearance(Self.policy(reduceMotion: true)) == .still)
    }

    @Test func orbIsSolidUnderReduceTransparencyAndIncreaseContrast() {
        #expect(LooprCoachOrb.Appearance(Self.policy(reduceTransparency: true)) == .solid)
        #expect(LooprCoachOrb.Appearance(Self.policy(increasedContrast: true)) == .solid)
        #expect(LooprCoachOrb.Appearance(Self.policy(reduceMotion: true, reduceTransparency: true)) == .solid)
    }

    @Test func orbSizesAndColoursFollowTheContract() {
        #expect(LooprCoachOrb.Size.xs.diameter == 16)
        #expect(LooprCoachOrb.Size.sm.diameter == 20)
        #expect(LooprCoachOrb.Size.regular.diameter == 24)
        #expect(LooprCoachOrb.turnSeconds == 6)
        #expect(LooprCoachOrb.tints == [.brand, .sleep, .protocol, .energy, .brand])
    }

    @Test func orbRendersAtEverySizeWithAndWithoutALabel() {
        for size in LooprCoachOrb.Size.allCases {
            for label in [nil, "Ask Loopr"] {
                let host = UIHostingController(rootView: LooprCoachOrb(size: size, accessibilityLabel: label))
                #expect(host.sizeThatFits(in: CGSize(width: 100, height: 100)).width == size.diameter)
            }
        }
    }
}
