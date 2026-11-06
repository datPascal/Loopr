import DesignSystem
import SwiftUI
import Testing

/// The week strip's dot mode (Fitness R1-DES-15): a dot per session, no caption in the column, and no clipping at
/// any text size.
@MainActor struct LooprWeekStripDotsTests {
    private var days: [LooprWeekStripDay] {
        [
            LooprWeekStripDay(identifier: "d-13", weekdayLetter: "M", dateNumeral: "13", caption: "Lower A, done", isDone: true,
                              accessibilityLabel: "Monday 13 November, done", marks: [.done, .planned]),
            LooprWeekStripDay(identifier: "d-14", weekdayLetter: "T", dateNumeral: "14", caption: "Upper A and Zone 2", isToday: true,
                              accessibilityLabel: "Tuesday 14 November, Upper A and Zone 2, today", marks: [.planned, .planned]),
            LooprWeekStripDay(identifier: "d-15", weekdayLetter: "W", dateNumeral: "15", caption: "Rest",
                              accessibilityLabel: "Wednesday 15 November, rest")
        ]
    }

    @Test func aColumnDrawsThreeDotsThenAPlus() {
        let five: [LooprWeekStripMark] = [.done, .done, .planned, .planned, .planned]
        let shown = LooprWeekStrip.shownMarks(five)
        #expect(shown.marks == [.done, .done, .planned] && shown.more)
        let two = LooprWeekStrip.shownMarks([.done, .planned])
        #expect(two.marks == [.done, .planned] && !two.more)
        #expect(LooprWeekStrip.shownMarks([]).marks.isEmpty)
    }

    @Test func marksDefaultToNoneSoCaptionCallersKeepWorking() {
        let day = LooprWeekStripDay(identifier: "d", weekdayLetter: "M", dateNumeral: "1", caption: "Rest", accessibilityLabel: "Monday")
        #expect(day.marks.isEmpty)
    }

    @Test func dotModeRendersAtEveryTextSizeAndStaysOneTargetTall() throws {
        let strip = LooprWeekStrip(days: days, accent: .strain, identifier: "strip", selection: "d-14") { _ in }
        for appearance in [ColorScheme.light, .dark] {
            let regular = try render(strip, appearance: appearance, size: .large, width: 358)
            #expect(regular.width == 358 && CGFloat(regular.height) >= LooprWeekStrip.minimumCellHeight)
            let largest = try render(strip, appearance: appearance, size: .accessibility5)
            #expect(CGFloat(largest.height) >= LooprWeekStrip.minimumCellHeight * 3)
        }
    }

    private func render(_ view: some View, appearance: ColorScheme, size: DynamicTypeSize, width: CGFloat = 320) throws -> CGImage {
        try #require(ImageRenderer(content: view.environment(\.colorScheme, appearance)
            .environment(\.dynamicTypeSize, size).frame(width: width)).cgImage)
    }
}
