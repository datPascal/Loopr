import Foundation
import Metal
import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

/// LV-01.2: the colour field draws per tab, pauses per the rules and falls back under the
/// accessibility settings. The rules are read from `LooprColorFieldPolicy` with injected inputs.
@MainActor struct LooprColorFieldTests {
    private static func policy(visible: Bool = true, lowPower: Bool = false, reduceMotion: Bool = false,
                               reduceTransparency: Bool = false, increasedContrast: Bool = false) -> LooprColorFieldPolicy {
        LooprColorFieldPolicy(isVisible: visible, isLowPowerModeEnabled: lowPower, reduceMotion: reduceMotion,
                              reduceTransparency: reduceTransparency, increasedContrast: increasedContrast)
    }

    @Test func fieldDriftsOnlyWhenVisibleWithFullPowerAndMotion() {
        #expect(Self.policy().rendering == .animated)
        #expect(Self.policy().ticks)
    }

    @Test func fieldHoldsAStillFrameWhenHidden() {
        #expect(Self.policy(visible: false).rendering == .still)
        #expect(!Self.policy(visible: false).ticks)
    }

    @Test func fieldHoldsAStillFrameInLowPowerMode() {
        #expect(Self.policy(lowPower: true).rendering == .still)
        #expect(!Self.policy(lowPower: true).ticks)
    }

    @Test func fieldHoldsAStillFrameUnderReduceMotion() {
        #expect(Self.policy(reduceMotion: true).rendering == .still)
        #expect(!Self.policy(reduceMotion: true).ticks)
    }

    @Test func reduceTransparencyDrawsAFlatWash() {
        #expect(Self.policy(reduceTransparency: true).rendering == .flatWash)
        #expect(Self.policy(visible: false, lowPower: true, reduceMotion: true, reduceTransparency: true).rendering == .flatWash)
        #expect(!Self.policy(reduceTransparency: true).ticks)
    }

    @Test func increasedContrastDrawsThePlainPage() {
        #expect(Self.policy(increasedContrast: true).rendering == .plain)
        #expect(Self.policy(reduceTransparency: true, increasedContrast: true).rendering == .plain)
        #expect(!Self.policy(increasedContrast: true).ticks)
    }

    @Test func everyInputCombinationTicksOnlyInTheOneAnimatedCase() {
        for bits in 0..<32 {
            let policy = Self.policy(visible: bits & 1 != 0, lowPower: bits & 2 != 0, reduceMotion: bits & 4 != 0,
                                     reduceTransparency: bits & 8 != 0, increasedContrast: bits & 16 != 0)
            #expect(policy.ticks == (bits == 1), "inputs \(bits)")
        }
    }

    @Test func eachTabFieldFollowsTheContract() {
        let leads: [LooprColorFieldTab: LooprColorToken] = [
            .today: .sleep, .food: .energy, .fitness: .strain, .protocol: .protocol, .data: .brand
        ]
        for tab in LooprColorFieldTab.allCases {
            let palette = LooprColorFieldPalette.tab(tab)
            #expect(palette.blobs.count == 3, "\(tab)")
            #expect(palette.blobs.first?.tint == leads[tab], "\(tab)")
            #expect(palette.accent == tab.accent, "\(tab)")
            #expect(palette.shaderValues.count == 3 * 6, "\(tab)")
            #expect(palette.shaderTints.count == LooprColorFieldPalette.maximumBlobs, "\(tab)")
            #expect(palette.blobs.allSatisfy { $0.lead >= 0 && $0.opacity > 0 && $0.opacity <= 1 }, "\(tab)")
        }
        #expect(LooprColorFieldTab.protocol.accent == .protocol)
        #expect(LooprColorFieldTab.food.accent == .energy)
        #expect(LooprColorFieldTab.fitness.accent == .strain)
        #expect(LooprColorFieldTab.today.accent == .brand)
        #expect(LooprColorFieldTab.data.accent == .brand)
    }

    @Test func blobsConvertTheContractBoxes() {
        // Protocol's second blob: `right:-25%;top:4%;width:62%;height:28%;animation-delay:-8s;opacity:.6`.
        let blob = LooprColorFieldPalette.tab(.protocol).blobs[1]
        #expect(blob.tint == .sleep)
        #expect(abs(blob.centre.x - 0.94) < 0.0001)
        #expect(abs(blob.centre.y - 0.18) < 0.0001)
        #expect(abs(blob.radius.width - 0.31) < 0.0001)
        #expect(abs(blob.radius.height - 0.14) < 0.0001)
        #expect(blob.opacity == 0.6)
        #expect(blob.lead == 8)
    }

    @Test func accentPicksItsTabField() {
        #expect(LooprColorFieldPalette.accent(.protocol) == .tab(.protocol))
        #expect(LooprColorFieldPalette.accent(.cyclePlum) == .tab(.protocol))
        #expect(LooprColorFieldPalette.accent(.energy) == .tab(.food))
        #expect(LooprColorFieldPalette.accent(.strain) == .tab(.fitness))
        #expect(LooprColorFieldPalette.accent(.brand) == .tab(.data))
        let heart = LooprColorFieldPalette.accent(.heart)
        #expect(heart.accent == .heart)
        #expect(heart.blobs.first?.tint == .heart)
        #expect(heart.blobs.count == 3)
    }

    @Test func lightModeIsFainterAndMultipliesTheGrain() {
        #expect(LooprColorFieldIntensity.forDark(true) == .dark)
        #expect(LooprColorFieldIntensity.forDark(false) == .light)
        #expect(LooprColorFieldIntensity.dark.aura == 0.55)
        #expect(LooprColorFieldIntensity.light.aura == 0.32)
        #expect(LooprColorFieldIntensity.light.aura < LooprColorFieldIntensity.dark.aura)
        #expect(LooprColorFieldIntensity.light.grain < LooprColorFieldIntensity.dark.grain)
        #expect(LooprColorFieldIntensity.light.multipliesGrain)
        #expect(!LooprColorFieldIntensity.dark.multipliesGrain)
        #expect(LooprColorFieldIntensity.light.wash < LooprColorFieldIntensity.dark.wash)
    }

    @Test func fieldRedrawsAtMostThirtyTimesASecond() {
        #expect(LooprColorField.frameInterval >= 1.0 / 30)
    }

    @Test func shaderFunctionLoadsFromThePackageBundle() throws {
        let bundle = LooprColorField.shaderBundle
        #expect(bundle.url(forResource: "default", withExtension: "metallib") != nil, "No default.metallib in \(bundle.bundlePath)")
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: bundle)
        #expect(library.makeFunction(name: LooprColorField.shaderFunctionName) != nil)
        _ = ShaderFunction(library: .bundle(bundle), name: LooprColorField.shaderFunctionName)
    }

    @Test func fieldRendersForEveryTabAndAppearance() {
        defer { DesignSystemRuntime.reset() }
        for increasedContrast in [false, true] {
            DesignSystemRuntime.apply(.init(appearance: .dark, increasedContrast: increasedContrast))
            for tab in LooprColorFieldTab.allCases {
                for style in [UIUserInterfaceStyle.light, .dark] {
                    let host = UIHostingController(rootView: LooprColorField(tab: tab))
                    host.overrideUserInterfaceStyle = style
                    host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
                    host.view.layoutIfNeeded()
                    #expect(host.view.bounds.width == 393)
                }
            }
        }
    }
}
