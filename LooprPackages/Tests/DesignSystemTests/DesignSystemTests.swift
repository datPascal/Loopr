import Foundation
import MapKit
import SwiftUI
import Testing
import UIKit
@testable import DesignSystem

@MainActor
struct DesignSystemTests {
    @Test func everySemanticColorResolves() {
        DesignSystemRuntime.reset()
        defer { DesignSystemRuntime.reset() }
        for token in LooprColorToken.allCases {
            _ = token.color
            let color = UIColor(token.color)
            for traits in [
                traits(style: .light, contrast: .normal),
                traits(style: .dark, contrast: .normal),
                traits(style: .light, contrast: .high),
                traits(style: .dark, contrast: .high)
            ] {
                let alpha = color.resolvedColor(with: traits).cgColor.alpha
                if token == .surfaceStroke,
                   traits.userInterfaceStyle == .light,
                   traits.accessibilityContrast == .normal {
                    #expect(alpha == 0)
                } else {
                    #expect(alpha > 0, "Unresolved color token: \(token)")
                }
            }
        }
    }

    @Test func runtimeTokenBridgeChangesPaletteSelectionAndMotion() {
        DesignSystemRuntime.reset()
        let light = UIColor(Color.loopr(.background)).resolvedColor(with: traits(style: .light, contrast: .normal))
        DesignSystemRuntime.apply(.init(appearance: .dark, increasedContrast: true, reduceMotion: true))
        let dark = UIColor(Color.loopr(.background)).resolvedColor(with: traits(style: .light, contrast: .normal))
        #expect(light != dark)
        #expect(DesignSystemRuntime.state().reduceMotion == true)
        _ = LooprMotion.stateChange
        DesignSystemRuntime.reset()
    }

    @Test func typographyDefinesScalableStyles() {
        #expect(LooprTextStyle.allCases.allSatisfy { $0.baseSize.isFinite && $0.baseSize > 0 })
        let readingStyles: [LooprTextStyle] = [.body, .prose, .label, .settingsRow, .rowTitle]
        #expect(readingStyles.allSatisfy { $0.baseSize >= 13 })
        let accessibilityTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        for style in LooprTextStyle.allCases {
            _ = style.font
            #expect(UIFontMetrics.default.scaledValue(for: style.baseSize, compatibleWith: accessibilityTraits) > style.baseSize)
        }
    }

    @Test func fontNoticesArePresentAndNonEmpty() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let notices = [
            repository.appendingPathComponent("Loopr/Loopr/Resources/Fonts/Manrope/Manrope-OFL.txt"),
            repository.appendingPathComponent("Loopr/Loopr/Resources/Fonts/BarlowCondensed/BarlowCondensed-OFL.txt")
        ]
        for notice in notices {
            let data = try Data(contentsOf: notice)
            #expect(!data.isEmpty)
        }
    }

    @Test func everyMetricStateHasDistinctAccessibleMeaning() {
        #expect(MetricState.allCases.count == 14)
        #expect(Set(MetricState.allCases.map(\.title)).count == 14)
        #expect(MetricState.absent.title != MetricState.measuredZero.title)
        #expect(MetricState.absent.detail != MetricState.measuredZero.detail)
        #expect(!MetricState.absent.isValuePresent)
        #expect(MetricState.measuredZero.isValuePresent)
    }

    @Test func metricCardNeverSubstitutesZeroForAbsent() {
        let absent = MetricCard(title: "Steps", value: nil, unit: "steps", state: .absent)
        let zero = MetricCard(title: "Steps", value: "0", unit: "steps", state: .measuredZero)
        #expect(absent.accessibilitySummary.contains("Not measured"))
        #expect(!absent.accessibilitySummary.contains("0"))
        #expect(zero.accessibilitySummary.contains("0"))
        #expect(zero.accessibilitySummary.contains("Measured zero"))
    }

    @Test func scoreArcStatesHaveAccessibleSummaries() {
        for state in GraphicDataState.allCases {
            let arc = ScoreArc(value: state == .absent ? nil : 72, trend: "up", confidence: "high confidence", state: state)
            #expect(!arc.accessibilitySummary.isEmpty)
        }
        #expect(ScoreArc(value: 72, state: .lowConfidence).accessibilitySummary.contains("Low confidence"))
        #expect(!ScoreArc(value: 72, state: .lowConfidence).accessibilitySummary.contains("lowConfidence"))
    }

    @Test func chartSummaryIncludesRangeAndUnit() {
        let chart = TrendChart(title: "Heart rate", unit: "beats per minute", samples: [
            ChartSample(label: "A", value: 52), ChartSample(label: "B", value: 74)
        ])
        #expect(chart.accessibilitySummary.contains("52"))
        #expect(chart.accessibilitySummary.contains("74"))
        #expect(chart.accessibilitySummary.contains("beats per minute"))
    }

    @Test func everyGraphicFamilyHasANonVisualSummary() {
        let hypnogram = Hypnogram(segments: [.init(id: 1, stage: .deep, durationMinutes: 20)])
        let zones = ZoneChart(zones: [.init(id: 1, name: "Recovery", minutes: 10, symbol: "1")])
        let route = RouteGraphic(coordinates: [.init(latitude: 1, longitude: 1)], distance: "5 kilometers", duration: "30 minutes")
        let recap = RecapChart(samples: [.init(label: "Week", value: 80)])
        #expect(hypnogram.accessibilitySummary.contains("deep"))
        #expect(zones.accessibilitySummary.contains("Recovery"))
        #expect(route.accessibilitySummary.contains("5 kilometers"))
        #expect(recap.accessibilitySummary.contains("Week"))
    }

    @Test func galleryAndEveryPrimitiveConstruct() {
        _ = DesignSystemGallery()
        _ = LooprSurface { Text("Surface") }
        _ = LooprSkeleton()
        _ = StatusChip("Fresh", symbol: "checkmark", tone: .positive)
        _ = LooprRow(title: "Row", symbol: "heart")
        _ = Hypnogram(segments: [.init(id: 1, stage: .deep, durationMinutes: 20)])
        _ = ZoneChart(zones: [.init(id: 1, name: "Zone 1", minutes: 10, symbol: "1")])
        _ = RecapChart(samples: [.init(label: "Week", value: 80)])
    }

    @Test func componentAccessibilityContractsAreExplicit() {
        for tone in ChipTone.allCases {
            let chip = StatusChip("Status", symbol: "checkmark.circle", tone: tone)
            #expect(chip.hasNonColorDifferentiator)
            #expect(!chip.accessibilitySummary.isEmpty)
        }

        let row = LooprRow(title: "Measurement quality", subtitle: "High confidence", symbol: "waveform.path.ecg")
        #expect(!row.accessibilitySummary.isEmpty)
        #expect(LooprButtonStyle.minimumTargetHeight >= 44)
        #expect(type(of: row).minimumTargetHeight >= 44)
    }

    @Test func scoreArcRenderingPerformanceAndAccessibilityModes() {
        assertRenderingBudget { ScoreArc(value: 82, trend: "up", confidence: "high confidence") }
    }

    @Test func trendChartRenderingPerformanceAndAccessibilityModes() {
        let samples = chartSamples(count: 500)
        assertRenderingBudget { TrendChart(title: "Heart rate", unit: "beats per minute", samples: samples) }
    }

    @Test func hypnogramRenderingPerformanceAndAccessibilityModes() {
        let segments = (0..<500).map {
            SleepSegment(id: $0, stage: SleepStage.allCases[$0 % SleepStage.allCases.count], durationMinutes: 2)
        }
        assertRenderingBudget { Hypnogram(segments: segments) }
    }

    @Test func zoneChartRenderingPerformanceAndAccessibilityModes() {
        let zones = (0..<100).map { ZoneSample(id: $0, name: "Zone \($0)", minutes: Double($0 + 1), symbol: "\($0 + 1)") }
        assertRenderingBudget { ZoneChart(zones: zones) }
    }

    @Test func routeGraphicRenderingPerformanceAndAccessibilityModes() {
        let coordinates: [CLLocationCoordinate2D] = (0..<500).map { index in
            let offset = Double(index) * 0.00001
            return CLLocationCoordinate2D(latitude: 37.77 + offset, longitude: -122.42 + offset)
        }
        assertRenderingBudget { RouteGraphic(coordinates: coordinates, distance: "5 kilometers", duration: "30 minutes") }
    }

    @Test func recapChartRenderingPerformanceAndAccessibilityModes() {
        let samples = chartSamples(count: 500)
        assertRenderingBudget { RecapChart(samples: samples) }
    }

    private func traits(style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast) -> UITraitCollection {
        UITraitCollection(mutations: {
            $0.userInterfaceStyle = style
            $0.accessibilityContrast = contrast
        })
    }

    private func chartSamples(count: Int) -> [ChartSample] {
        (0..<count).map { ChartSample(label: "\($0)", value: Double(($0 * 17) % 100)) }
    }

    private func assertRenderingBudget<Content: View>(@ViewBuilder content: () -> Content) {
        let modes = [
            traits(style: .light, contrast: .normal),
            traits(style: .dark, contrast: .normal),
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge),
            traits(style: .light, contrast: .high)
        ]
        for mode in modes {
            render(AnyView(content()), traits: mode)
        }
        render(AnyView(content().transaction { $0.disablesAnimations = true }))

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
        let parent = UIViewController()
        let controller = UIHostingController(rootView: view)
        parent.addChild(controller)
        if let traits {
            controller.traitOverrides.userInterfaceStyle = traits.userInterfaceStyle
            controller.traitOverrides.accessibilityContrast = traits.accessibilityContrast
            controller.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
        }
        parent.view.addSubview(controller.view)
        controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.didMove(toParent: parent)
    }
}
