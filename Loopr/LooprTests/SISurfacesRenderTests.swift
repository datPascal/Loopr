import DesignSystem
import SwiftUI
import WidgetKit
import XCTest
@testable import Loopr

@MainActor
final class SISurfacesRenderTests: XCTestCase {
    func testGlanceViewsInLightAndDark() throws {
        let now = Date()
        let original = DesignSystemRuntime.state()
        defer { DesignSystemRuntime.apply(original) }
        for appearance in ["light", "dark"] {
            let scheme: ColorScheme = appearance == "dark" ? .dark : .light
            DesignSystemRuntime.apply(.init(appearance: appearance == "dark" ? .dark : .light, reduceMotion: true))
            for state in ["ready", "steady", "flagged", "learning", "empty", "stale", "flagged-unscored"] {
                let snapshot = DebugCaptureFixtures.siSurfacesSnapshot(state: state, now: now)
                for (name, family, size) in [
                    ("widget-small", WidgetFamily.systemSmall, CGSize(width: 170, height: 170)),
                    ("widget-medium", .systemMedium, CGSize(width: 360, height: 170)),
                    ("widget-circular", .accessoryCircular, CGSize(width: 64, height: 64)),
                    ("widget-rectangular", .accessoryRectangular, CGSize(width: 170, height: 72)),
                    ("widget-inline", .accessoryInline, CGSize(width: 340, height: 36))
                ] {
                    try attach(LooprTodayWidgetContent(snapshot: snapshot, now: now, family: family)
                        .padding(family == .systemSmall || family == .systemMedium ? 16 : 4),
                        name: "\(appearance)-si-polish-\(name)-\(state)", size: size, scheme: scheme)
                }
                if let snapshot {
                    try attach(VStack(alignment: .leading, spacing: 10) { LooprWatchSummaryRows(snapshot: snapshot, now: now) }.padding(12),
                        name: "\(appearance)-si-polish-watch-dashboard-\(state)",
                        size: CGSize(width: 240, height: 440), scheme: scheme)
                } else {
                    try attach(LooprWatchEmptySummary().padding(12), name: "\(appearance)-si-polish-watch-dashboard-empty",
                        size: CGSize(width: 240, height: 440), scheme: scheme)
                }
                for (name, family, size) in [
                    ("watch-circular", WidgetFamily.accessoryCircular, CGSize(width: 64, height: 64)),
                    ("watch-rectangular", .accessoryRectangular, CGSize(width: 170, height: 72))
                ] {
                    try attach(LooprWatchComplicationContent(family: family, snapshot: snapshot, now: now).padding(4),
                        name: "\(appearance)-si-polish-\(name)-\(state)", size: size, scheme: scheme)
                }
            }
            for (name, family, size) in [
                ("widget-small", WidgetFamily.systemSmall, CGSize(width: 170, height: 170)),
                ("widget-medium", .systemMedium, CGSize(width: 360, height: 170))
            ] {
                try attach(LooprTodayWidgetContent(snapshot: DebugCaptureFixtures.siSurfacesSnapshot(state: "ready", now: now),
                        now: now, family: family).padding(16).environment(\.dynamicTypeSize, .accessibility5),
                    name: "\(appearance)-si-polish-\(name)-largest-text", size: size, scheme: scheme)
            }
        }
    }

    private func attach(_ content: some View, name: String, size: CGSize, scheme: ColorScheme) throws {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height)
            .background(Color.loopr(.background))
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, name)
        XCTAssertEqual(image.size, size)
        let attachment = XCTAttachment(data: try XCTUnwrap(image.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
