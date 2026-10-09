import Foundation
import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

@MainActor
struct ProgressRingTests {
    @Test func boundedScaleFillsProportionallyAndClampsAtOneLap() {
        let recovery = LooprRingScale(fullValue: 100)
        #expect(recovery.fraction(for: 0) == 0)
        #expect(recovery.fraction(for: 64) == 0.64)
        #expect(recovery.fraction(for: 100) == 1)
        #expect(recovery.fraction(for: 140) == 1)
        #expect(recovery.fraction(for: -5) == 0)

        let strain = LooprRingScale(fullValue: 21)
        #expect(abs((strain.fraction(for: 3.6) ?? -1) - 3.6 / 21) < 1e-12)
        #expect(strain.fraction(for: 24) == 1)
    }

    @Test func overflowScaleRunsIntoASecondLapAndStopsAtTwo() {
        let sleepGoal = LooprRingScale(fullValue: 480, allowsOverflow: true)
        #expect(sleepGoal.fraction(for: 240) == 0.5)
        #expect(sleepGoal.fraction(for: 528) == 1.1)
        #expect(sleepGoal.fraction(for: 960) == 2)
        #expect(sleepGoal.fraction(for: 1_500) == LooprRingScale.maximumLaps)
        #expect(sleepGoal.percent(for: 528) == 110)
    }

    @Test func missingValueOrUnusableScaleIsNotAZeroFill() {
        #expect(LooprRingScale(fullValue: 100).fraction(for: nil) == nil)
        #expect(LooprRingScale(fullValue: 100).fraction(for: .nan) == nil)
        #expect(LooprRingScale(fullValue: 100).fraction(for: .infinity) == nil)
        #expect(LooprRingScale(fullValue: 0).fraction(for: 5) == nil)
        #expect(LooprRingScale(fullValue: -21).fraction(for: 5) == nil)
        #expect(LooprRingScale(fullValue: .nan).fraction(for: 5) == nil)
        #expect(LooprRingScale(fullValue: 100).percent(for: nil) == nil)
    }

    @Test func countUpFormatsLandOnTheDisplayStrings() {
        #expect(LooprRingNumberFormat.integer.text(for: 21) == "21")
        #expect(LooprRingNumberFormat.integer.text(for: 20.6) == "21")
        #expect(LooprRingNumberFormat.oneDecimal.text(for: 3.6) == "3.6")
        #expect(LooprRingNumberFormat.oneDecimal.text(for: 0) == "0.0")
        // Same truncation the Today derivation uses for "8:15".
        #expect(LooprRingNumberFormat.hoursMinutes.text(for: 495) == "8:15")
        #expect(LooprRingNumberFormat.hoursMinutes.text(for: 495.9) == "8:15")
        #expect(LooprRingNumberFormat.hoursMinutes.text(for: 62) == "1:02")
        #expect(LooprRingNumberFormat.hoursMinutesSpelled.text(for: 462) == "7 h 42 m")
        // A spring may undershoot below zero on the way in; never print "-0:01".
        #expect(LooprRingNumberFormat.hoursMinutes.text(for: -3) == "0:00")
        #expect(LooprRingNumberFormat.integer.text(for: .nan) == "0")
    }

    @Test func ringPresentationCannotPassEitherReading() {
        let samples = stride(from: -0.2, through: 1.2, by: 0.01)
        for phase in samples {
            let proposed = 72 * phase
            let shown = LooprRingMotion.clamped(proposed, from: 0, to: 72)
            #expect((0...72).contains(shown))
            #expect(Int(LooprRingNumberFormat.integer.text(for: shown))! <= 72)

            let decreasing = LooprRingMotion.clamped(73 - phase, from: 73, to: 72)
            #expect((72...73).contains(decreasing))
        }
    }

    @Test func progressRingRenderingPerformanceAndAccessibilityModes() {
        assertRenderingBudget {
            HStack {
                LooprProgressRing(value: 495, scale: LooprRingScale(fullValue: 450, allowsOverflow: true),
                                  text: "8:15", format: .hoursMinutes, accent: .sleep, diameter: 74)
                LooprProgressRing(value: nil, scale: LooprRingScale(fullValue: 100),
                                  text: "—", accent: .recovery, diameter: 74)
                LooprProgressRing(value: 3.6, scale: LooprRingScale(fullValue: 21),
                                  text: "3.6", format: .oneDecimal, accent: .strain, diameter: 74, revealDelay: 0.16)
                LooprProgressRing(value: 21, scale: LooprRingScale(fullValue: 100),
                                  text: "21", format: .integer, accent: .stress, diameter: 74, revealDelay: 0.24)
            }
        }
    }

    @Test func ringHeroRenderingPerformanceAndAccessibilityModes() {
        assertRenderingBudget {
            LooprRingHero(value: 8.6, scale: LooprRingScale(fullValue: 21), text: "8.6", format: .oneDecimal,
                          caption: "Strain score", accent: .strain) {
                Text("High confidence")
            }
        }
    }

    // MARK: Helpers

    private func assertRenderingBudget<Content: View>(@ViewBuilder content: () -> Content) {
        let modes: [UITraitCollection] = [
            UITraitCollection(mutations: { $0.userInterfaceStyle = .light }),
            UITraitCollection(mutations: { $0.userInterfaceStyle = .dark }),
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge),
            UITraitCollection(mutations: { $0.userInterfaceStyle = .dark; $0.accessibilityContrast = .high })
        ]
        for mode in modes {
            render(AnyView(content()), traits: mode)
        }
        render(AnyView(content()))
        let iterations = 10
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            render(AnyView(content()))
        }
        let averageFrameTime = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations)
        #expect(averageFrameTime < 0.016, "Average main-thread layout exceeded the 16 ms frame budget: \(averageFrameTime) seconds")
    }

    private func render(_ view: AnyView, traits: UITraitCollection? = nil) {
        let controller = UIHostingController(rootView: view)
        if let traits {
            controller.traitOverrides.userInterfaceStyle = traits.userInterfaceStyle
            controller.traitOverrides.accessibilityContrast = traits.accessibilityContrast
            controller.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
        }
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 400)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }
}
