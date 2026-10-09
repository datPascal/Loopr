import CoreLocation
import SwiftUI

public struct DesignSystemGallery: View {
    private enum Section: String, CaseIterable {
        case top
        case recovery
        case deltas
        case contributors
        case stages
        case ledger
        case paired
        case scrub
        case rows
        case spectral
        case trend
        case zones
        case recap
        case states
        case buttonStyles
        case menuGroup
        case toggleRow
        case textFieldRow
        case textEditorRow
        case pickerRow
        case inlineMessage
        case detailScaffold

        var identifier: String { "design-system-section-\(rawValue)" }
    }

    private let initialSection: Section?
    @State private var sampleToggle = true
    @State private var sampleText = "7:42"
    @State private var sampleEditorText = ""
    @State private var samplePicker = "Metric"
    @State private var highlightedStage: SleepStage?
    @State private var trendRange: LooprChartRange = .month

    public init(initialSection: String? = nil) {
        self.initialSection = initialSection.flatMap(Section.init(rawValue:))
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LooprSpacing.xl) {
                    header
                        .id(Section.top.identifier)
                        .accessibilityIdentifier(Section.top.identifier)
                    LooprGalleryKitSections(highlightedStage: $highlightedStage, trendRange: $trendRange)
                    spectralShowcase
                        .id(Section.spectral.identifier)
                        .accessibilityIdentifier(Section.spectral.identifier)
                    MetricCard(title: "Recovery", value: "82", unit: "%", trend: "7% above baseline", confidence: "High confidence", state: .partial, accent: .recovery)
                    ScoreArc(value: 82, trend: "Up 7 percent", confidence: "High confidence", accent: .recovery)
                        .frame(maxWidth: 280)
                        .frame(maxWidth: .infinity)
                    TrendChart(title: "Seven-day HRV", unit: "milliseconds", samples: Self.trend, accent: .heart)
                        .id(Section.trend.identifier)
                        .accessibilityIdentifier(Section.trend.identifier)
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText("Sleep stages", style: .title)
                            Hypnogram(segments: Self.sleep)
                        }
                    }
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText("Heart-rate zones", style: .title)
                            ZoneChart(zones: Self.zones)
                        }
                    }
                    .id(Section.zones.identifier)
                    .accessibilityIdentifier(Section.zones.identifier)
                    LooprSurface {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText("Monthly recap", style: .title)
                            RecapChart(samples: Self.recap)
                        }
                    }
                    .id(Section.recap.identifier)
                    .accessibilityIdentifier(Section.recap.identifier)
                    RouteGraphic(coordinates: Self.route, distance: "5.2 kilometers", duration: "28 minutes")
                        .frame(height: 240)
                    LooprSurface {
                        VStack(spacing: LooprSpacing.md) {
                            ForEach(MetricState.allCases, id: \.self) { StateMessage($0) }
                        }
                    }
                    .id(Section.states.identifier)
                    .accessibilityIdentifier(Section.states.identifier)
                    LooprSurface {
                        VStack(spacing: LooprSpacing.md) {
                            StatusChip("Fresh", symbol: "checkmark.circle.fill", tone: .positive)
                            LooprRow(title: "Measurement quality", subtitle: "High confidence", symbol: "waveform.path.ecg")
                            Button("Review details") {}
                                .buttonStyle(LooprButtonStyle())
                        }
                    }
                    buttonStylesShowcase
                        .id(Section.buttonStyles.identifier)
                        .accessibilityIdentifier(Section.buttonStyles.identifier)
                    menuGroupShowcase
                        .id(Section.menuGroup.identifier)
                        .accessibilityIdentifier(Section.menuGroup.identifier)
                    toggleRowShowcase
                        .id(Section.toggleRow.identifier)
                        .accessibilityIdentifier(Section.toggleRow.identifier)
                    textFieldRowShowcase
                        .id(Section.textFieldRow.identifier)
                        .accessibilityIdentifier(Section.textFieldRow.identifier)
                    textEditorRowShowcase
                        .id(Section.textEditorRow.identifier)
                        .accessibilityIdentifier(Section.textEditorRow.identifier)
                    pickerRowShowcase
                        .id(Section.pickerRow.identifier)
                        .accessibilityIdentifier(Section.pickerRow.identifier)
                    inlineMessageShowcase
                        .id(Section.inlineMessage.identifier)
                        .accessibilityIdentifier(Section.inlineMessage.identifier)
                    detailScaffoldShowcase
                        .id(Section.detailScaffold.identifier)
                        .accessibilityIdentifier(Section.detailScaffold.identifier)
                }
                .padding(LooprSpacing.screenGutter)
            }
            .task(id: initialSection) {
                guard let initialSection else { return }
                await Task.yield()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(initialSection.identifier, anchor: .top)
                }
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("Design System")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.loopr(.background), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .accessibilityIdentifier("design-system-gallery")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText("LOOPR", style: .overline, color: .brand)
            LooprText("Native health, clearly expressed.", style: .titleLarge)
            LooprText("System behavior first. Data semantics always visible.", color: .inkSecondary)
        }
    }

    private var spectralShowcase: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            LooprText("SPECTRAL LENS", style: .sectionLabel, color: .brand)
            StickyHeader(
                title: "Sleep",
                meta: "LAST NIGHT · THU 27 → FRI 28 AUG",
                status: StatusChip("Partial data", symbol: "circle.lefthalf.filled", tone: .brand)
            )
            SpectralLens(value: "7:42", caption: "Main sleep", accent: .sleep)
            HairlineMetricList(rows: [
                HairlineMetricRow(title: "Duration", confidence: "High confidence", value: "7:42", unit: "hours"),
                HairlineMetricRow(title: "Efficiency", confidence: "High confidence", value: "91", unit: "%"),
                HairlineMetricRow(title: "Sleep consistency", confidence: "6 of 7 nights", value: "86", unit: "%", accent: .sleep),
                HairlineMetricRow(title: "Night timeline", value: "", showsDisclosure: true, action: {})
            ])
            HStack(spacing: LooprSpacing.sm) {
                StatusChip("Fresh", symbol: "checkmark.circle.fill", tone: .positive)
                StatusChip("Partial data", symbol: "circle.lefthalf.filled", tone: .brand)
            }
            Button("Primary action") {}
                .buttonStyle(LooprButtonStyle())
        }
    }

    private var buttonStylesShowcase: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText("BUTTON STATES", style: .sectionLabel, color: .brand)
            LooprFormCard {
                VStack(spacing: LooprSpacing.sm) {
                    Button("Accent primary action") {}
                        .buttonStyle(LooprPrimaryButtonStyle(accent: .heart))

                    Button("Disabled primary action") {}
                        .buttonStyle(LooprPrimaryButtonStyle())
                        .disabled(true)

                    Button("Disabled destructive action", role: .destructive) {}
                        .buttonStyle(LooprDestructiveButtonStyle())
                        .disabled(true)
                }
            }
        }
    }

    private var menuGroupShowcase: some View {
        LooprMenuGroup(
            title: "Settings",
            rows: [
                LooprMenuItem(
                    title: "Privacy",
                    value: "On device",
                    accessibilityIdentifier: "gallery-privacy"
                ) {},
                LooprMenuItem(
                    title: "Units",
                    value: "Metric",
                    accessibilityIdentifier: "gallery-units"
                ) {}
            ]
        )
    }

    private var toggleRowShowcase: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText("TOGGLE ROW", style: .sectionLabel, color: .brand)
            LooprFormCard(padding: LooprSpacing.none) {
                LooprToggleRow(
                    title: "Automatic sync",
                    subtitle: "Keep measurements current",
                    isOn: $sampleToggle
                )
            }
        }
    }

    private var textFieldRowShowcase: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText("TEXT FIELD ROW", style: .sectionLabel, color: .brand)
            LooprFormCard(padding: LooprSpacing.none) {
                LooprTextFieldRow(title: "Sleep target", placeholder: "Enter a value", text: $sampleText)
            }
        }
    }

    private var textEditorRowShowcase: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText("TEXT EDITOR ROW", style: .sectionLabel, color: .brand)
            LooprFormCard(padding: LooprSpacing.none) {
                LooprTextEditorRow(
                    title: "Notes",
                    placeholder: "Add a note",
                    text: $sampleEditorText
                )
            }
        }
    }

    private var pickerRowShowcase: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText("PICKER ROW", style: .sectionLabel, color: .brand)
            LooprFormCard(padding: LooprSpacing.none) {
                LooprPickerRow(
                    title: "Units",
                    selection: $samplePicker,
                    options: ["Metric", "Imperial"],
                    label: { $0 }
                )
            }
        }
    }

    private var inlineMessageShowcase: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText("INLINE MESSAGE", style: .sectionLabel, color: .brand)
            LooprFormCard {
                LooprInlineMessage(
                    "The strap needs to reconnect before syncing.",
                    tone: .warning
                )
            }
        }
    }

    private var detailScaffoldShowcase: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprText("DETAIL SCAFFOLD", style: .sectionLabel, color: .brand)
            LooprDetailScaffold {
                LooprFormCard {
                    LooprText("Pushed detail content", style: .settingsRow)
                }
            }
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
        }
    }

    private static let trend = [
        ChartSample(label: "M", value: 54), ChartSample(label: "T", value: 58),
        ChartSample(label: "W", value: 56), ChartSample(label: "T2", value: 61),
        ChartSample(label: "F", value: 63), ChartSample(label: "S", value: 66),
        ChartSample(label: "S2", value: 64)
    ]

    private static let sleep = [
        SleepSegment(id: 1, stage: .awake, durationMinutes: 12),
        SleepSegment(id: 2, stage: .light, durationMinutes: 74),
        SleepSegment(id: 3, stage: .deep, durationMinutes: 52),
        SleepSegment(id: 4, stage: .rem, durationMinutes: 41),
        SleepSegment(id: 5, stage: .light, durationMinutes: 63)
    ]

    private static let zones = [
        ZoneSample(id: 1, name: "Recovery", minutes: 9, symbol: "1"),
        ZoneSample(id: 2, name: "Aerobic", minutes: 13, symbol: "2"),
        ZoneSample(id: 3, name: "Tempo", minutes: 5, symbol: "3"),
        ZoneSample(id: 4, name: "Peak", minutes: 1, symbol: "4")
    ]

    private static let recap = [
        ChartSample(label: "W1", value: 68), ChartSample(label: "W2", value: 74),
        ChartSample(label: "W3", value: 71), ChartSample(label: "W4", value: 82)
    ]

    private static let route = [
        CLLocationCoordinate2D(latitude: 37.776, longitude: -122.424),
        CLLocationCoordinate2D(latitude: 37.779, longitude: -122.419),
        CLLocationCoordinate2D(latitude: 37.783, longitude: -122.416),
        CLLocationCoordinate2D(latitude: 37.786, longitude: -122.411)
    ]
}

#Preview("Gallery") {
    NavigationStack { DesignSystemGallery() }
}
