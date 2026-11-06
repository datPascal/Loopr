import Foundation
import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

// The pure parts of LooprTimelineRow: what VoiceOver reads, how a row ahead is dimmed and the target height.

@MainActor
struct TimelineRowTests {
    @Test func spokenLabelJoinsTimeTitleAndDetail() {
        let model = LooprTimelineRowModel(time: "06:52", title: "Woke up", detail: "Smart alarm, 8 min early")
        #expect(model.accessibilityLabel == "06:52, Woke up, Smart alarm, 8 min early")
        #expect(!model.isDimmed)
        #expect(model.opacity == 1)
    }

    @Test func aRowAheadIsDimmedAndSaysUpcoming() {
        let model = LooprTimelineRowModel(time: "18:00", title: "Upper A", detail: "Planned", isDimmed: true)
        #expect(model.opacity == LooprTimelineRowModel.dimmedOpacity)
        #expect(model.opacity < 1)
        #expect(model.accessibilityLabel == "18:00, Upper A, Planned, upcoming")
    }

    @Test func aBlankDetailIsDroppedFromTheRowAndTheLabel() {
        let model = LooprTimelineRowModel(time: "22:45", title: "Bedtime", detail: "   ")
        #expect(model.detail == nil)
        #expect(model.accessibilityLabel == "22:45, Bedtime")
        #expect(LooprTimelineRowModel(time: "22:45", title: "Bedtime").detail == nil)
    }

    @Test func dimmedRowsStayLegible() {
        #expect(LooprTimelineRowModel.dimmedOpacity >= 0.4)
        #expect(LooprTimelineRowModel.dimmedOpacity < 1)
    }

    @Test func inLightModeARowAheadKeepsItsTimeAndDetailAtFullStrength() {
        let model = LooprTimelineRowModel(time: "18:00", title: "Upper A", detail: "Planned", isDimmed: true)
        #expect(model.opacity(isDark: false) == 1)
        // Dark mode keeps the row at full strength with the standard ink and mutes only the time (R1-OPT-22).
        #expect(model.opacity(isDark: true) == 1)
        #expect(model.titleToken(isDark: false) == .inkSecondary)
        #expect(model.titleToken(isDark: true) == .ink)
        #expect(model.timeToken(isDark: true) == .inkMuted)
        #expect(model.timeToken(isDark: false) == .inkSecondary)
        #expect(LooprTimelineRowModel(time: "06:52", title: "Woke up").timeToken(isDark: true) == .inkSecondary)
        #expect(LooprTimelineRowModel(time: "06:52", title: "Woke up").titleToken(isDark: false) == .ink)
        // The colour a dimmed row draws its time, detail and title in, on the card behind it.
        DesignSystemRuntime.reset()
        let light = UITraitCollection(userInterfaceStyle: .light)
        let text = UIColor(Color.loopr(.inkSecondary)).resolvedColor(with: light)
        let card = UIColor(Color.loopr(.sheetFill)).resolvedColor(with: light)
        #expect(contrast(text, card) >= 4.5)
    }

    private func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&r, green: &g, blue: &bl, alpha: &alpha)
            func linear(_ value: CGFloat) -> Double { value <= 0.03928 ? Double(value) / 12.92 : pow((Double(value) + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(bl)
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    @Test func rowIsAtLeastOneInteractiveRowTall() {
        #expect(LooprTimelineRow.minimumHeight >= 56)
        #expect(LooprTimelineRow.minimumHeight == LooprSpacing.interactiveRowHeight)
    }
}
