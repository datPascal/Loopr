import Combine
import MapKit
import SwiftUI
import DesignSystem

public enum RouteRoute: Hashable, Sendable, CaseIterable {
    case map
    case splits
    case sharePreview
}

public enum RouteScreenStateFixtures {
    public static let allStates = MetricState.allCases
    public static let accessibilityIdentifiers = ["route-screen", "route-graphic", "route-map", "route-splits", "route-share-preview"]
    public static let statesByScreen = Dictionary(uniqueKeysWithValues: accessibilityIdentifiers.map { ($0, allStates) })
    public static func accessibilitySummary(for state: MetricState) -> String { "\(state.title). \(state.detail)" }
}

@MainActor
public final class RouteViewModel: ObservableObject {
    @Published public private(set) var snapshot: RouteScreenSnapshot
    @Published public private(set) var route: RouteRecord?
    private(set) var requestedWorkoutID: String?
    private let recorder: RouteRecorder?

    public init(recorder: RouteRecorder? = nil) {
        self.recorder = recorder
        snapshot = RouteScreenSnapshot(state: .loading, summary: "Route loading")
    }

    public func load(workoutID: String) async {
        requestedWorkoutID = workoutID
        guard let recorder else {
            snapshot = RouteScreenSnapshot(state: .noRecords, summary: "No route recorded")
            return
        }
        do {
            route = try await recorder.recover(workoutID: workoutID)
            snapshot = RouteScreenSnapshot(state: .ready, summary: "Route ready")
        } catch RouteError.missingRoute {
            route = nil
            snapshot = RouteScreenSnapshot(state: .noRecords, summary: "No route recorded")
        } catch {
            snapshot = RouteScreenSnapshot(state: .recoverableError, summary: "Route could not be loaded")
        }
    }

    @discardableResult
    public func deleteLoadedRoute() async -> RouteDeletionReceipt? {
        guard let route, let recorder else { return nil }
        do {
            let receipt = try await recorder.delete(workoutID: route.workoutID)
            self.route = nil
            snapshot = RouteScreenSnapshot(state: .noRecords, summary: "No route recorded")
            return receipt
        } catch {
            snapshot = RouteScreenSnapshot(state: .recoverableError, summary: "Route could not be deleted")
            return nil
        }
    }

    public func reportRecordingFailure() {
        snapshot = RouteScreenSnapshot(state: .recoverableError, summary: "Route recording could not be saved")
    }

    public func exportLoadedRoute(includeLocation: Bool = false, exporter: any RouteExporter = LocalRouteExporter()) async throws -> RouteExportPayload {
        guard let route else { throw RouteError.missingRoute }
        return try await exporter.export(route: route, request: RouteExportRequest(includeLocation: includeLocation))
    }
}

public enum RouteFixtures {
    public static let completedWalk: RouteRecord = {
        let first = RoutePoint(timestamp: Date(timeIntervalSince1970: 1_700_000_000), latitude: 40, longitude: -73, horizontalAccuracy: 5, speedMetersPerSecond: 2)
        let second = RoutePoint(timestamp: Date(timeIntervalSince1970: 1_700_006_000), latitude: 40, longitude: -72.99, horizontalAccuracy: 5, speedMetersPerSecond: 2)
        return RouteRecord(workoutID: "fixture-route", activity: .walk, points: [first, second], completed: true)
    }()
}

public struct RouteScreen: View {
    @ObservedObject private var viewModel: RouteViewModel
    private let route: (RouteRoute) -> Void

    public init(viewModel: RouteViewModel, route: @escaping (RouteRoute) -> Void = { _ in }) {
        self.viewModel = viewModel
        self.route = route
    }

    public var body: some View {
        VStack(spacing: LooprSpacing.none) {
            StickyHeader(
                title: "Route",
                meta: headerMeta,
                status: headerStatus
            )
            // Both screens sit in a navigation stack, so the header joins
            // the system bar instead of drawing a second bar under it.
            .looprHeaderInNavigationBar()
            .zIndex(1)

            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    bodyContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.md)
                .padding(.bottom, LooprSpacing.tabBarClearance)
            }
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .navigationTitle("")
        .accessibilityIdentifier("route-screen")
    }

    // Split into three small builders on purpose. As one switch with nested
    // conditionals it was complex enough that the type checker gave up without
    // producing a diagnostic.
    @ViewBuilder
    private var bodyContent: some View {
        switch viewModel.snapshot.state {
        case .loading:
            RouteLoadingSurface()
        case .ready:
            readyContent
        case .noRecords:
            RouteStateSurface(state: .noRecords)
        default:
            fallbackContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let record = viewModel.route {
            if record.hasUsableGPS {
                RouteOverviewContent(record: record, route: route)
            } else {
                RouteNoGPSSurface()
            }
        } else {
            RouteStateSurface(state: .noRecords)
        }
    }

    private var fallbackContent: some View {
        let snapshotState = viewModel.snapshot.state
        var message: String?
        if snapshotState.isError {
            message = viewModel.snapshot.summary
        }
        var retry: (() -> Void)?
        if snapshotState == .recoverableError {
            retry = { self.retryLoad() }
        }
        return RouteStateSurface(
            state: snapshotState.metricState,
            message: message,
            retry: retry
        )
    }

    private func retryLoad() {
        let workoutID = viewModel.requestedWorkoutID ?? RouteFixtures.completedWalk.workoutID
        Task { await viewModel.load(workoutID: workoutID) }
    }

    private var headerStatus: StatusChip {
        switch viewModel.snapshot.state {
        case .ready:
            if let record = viewModel.route {
                if record.hasUsableGPS {
                    return StatusChip("Recorded", symbol: "checkmark.circle", accent: .movement)
                }
                return StatusChip(MetricState.absent.title, symbol: MetricState.absent.symbol, accent: .movement)
            }
            return StatusChip(MetricState.noRecords.title, symbol: MetricState.noRecords.symbol, accent: .movement)
        default:
            let state = viewModel.snapshot.state.metricState
            return StatusChip(state.title, symbol: state.symbol, accent: .movement)
        }
    }

    private var headerMeta: String {
        guard let record = viewModel.route else { return "RECORDED ROUTE" }
        let state = record.hasUsableGPS ? "RECORDED ROUTE" : "GPS ABSENT"
        return "\(record.activity.rawValue.uppercased()) · \(state)"
    }
}

public struct RouteDestinationScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    public let route: RouteRoute
    public let record: RouteRecord

    public init(route: RouteRoute, record: RouteRecord = RouteFixtures.completedWalk) {
        self.route = route
        self.record = record
    }

    public var body: some View {
        LooprDetailScaffold {
            destinationContent
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.movement))
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch route {
        case .map:
            if record.hasUsableGPS {
                RouteGraphicHero(
                    record: record,
                    title: "Route map",
                    graphicIdentifier: "route-map-graphic"
                )

                RouteSummarySection(record: record)
            } else {
                RouteNoGPSSurface()
            }
        case .splits:
            if record.hasUsableGPS {
                RouteSplitsContent(record: record)
            } else {
                RouteNoGPSSurface()
            }
        case .sharePreview:
            RouteSharePreviewPanel(record: record, exporter: LocalRouteExporter())
        }
    }

    private var title: String {
        switch route {
        case .map: "Route map"
        case .splits: "Route splits"
        case .sharePreview: "Route share preview"
        }
    }

    private var identifier: String {
        switch route {
        case .map: "route-map-screen"
        case .splits: "route-splits-screen"
        case .sharePreview: "route-share-preview-screen"
        }
    }
}

public struct RouteSharePreviewScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    public let record: RouteRecord
    private let exporter: any RouteExporter

    public init(
        record: RouteRecord = RouteFixtures.completedWalk,
        exporter: any RouteExporter = LocalRouteExporter()
    ) {
        self.record = record
        self.exporter = exporter
    }

    public var body: some View {
        LooprDetailScaffold {
            RouteSharePreviewPanel(record: record, exporter: exporter)
        }
        .navigationTitle("Route share preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(LooprAppearance.isDark(colorScheme) ? .dark : .light, for: .navigationBar)
        .tint(Color.loopr(.movement))
        .accessibilityIdentifier("route-share-preview-screen")
    }
}

private struct RouteOverviewContent: View {
    let record: RouteRecord
    let route: (RouteRoute) -> Void

    private var primitive: RoutePrimitiveData { RoutePrimitiveData(route: record) }

    var body: some View {
        RouteGraphicHero(record: record, title: "Recorded route", graphicIdentifier: "route-graphic")

        RouteSummarySection(record: record)

        if !zoneSamples(for: record).isEmpty {
            RouteZoneChartSection(zones: zoneSamples(for: record))
        }

        if !primitive.zoneSegments.isEmpty {
            LooprSectionGroup(title: "Route segments") {
                RouteSegmentMetricList(segments: primitive.zoneSegments)
            }
        }

        LooprMenuGroup(
            title: "Explore",
            rows: [
                LooprMenuItem(
                    title: "Map",
                    accessibilityIdentifier: "route-map",
                    action: { route(.map) }
                ),
                LooprMenuItem(
                    title: "Splits",
                    accessibilityIdentifier: "route-splits",
                    action: { route(.splits) }
                ),
                LooprMenuItem(
                    title: "Share preview",
                    accessibilityIdentifier: "route-share-preview",
                    action: { route(.sharePreview) }
                )
            ]
        )
    }
}

private struct RouteSplitsContent: View {
    let record: RouteRecord

    private var primitive: RoutePrimitiveData { RoutePrimitiveData(route: record) }

    var body: some View {
        LooprSectionGroup(title: "Splits") {
            if primitive.splits.isEmpty {
                LooprFormCard {
                    LooprInlineMessage(
                        "No complete kilometre splits were recorded.",
                        tone: .neutral
                    )
                }
            } else {
                HairlineMetricList(rows: routeSplitRows(for: primitive.splits))
            }
        }

        RouteGraphicHero(record: record, title: "Recorded route")

        if !zoneSamples(for: record).isEmpty {
            RouteZoneChartSection(zones: zoneSamples(for: record))
        }

        RouteSummarySection(record: record)
    }
}

private struct RouteGraphicHero: View {
    let record: RouteRecord
    let title: String
    var graphicIdentifier: String?

    var body: some View {
        LooprSurface(emphasis: .hero(.movement)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                HStack(alignment: .center, spacing: LooprSpacing.sm) {
                    LooprText(title, style: .cardTitle)
                    Spacer(minLength: LooprSpacing.sm)
                    StatusChip(
                        record.completed ? "Completed" : "In progress",
                        symbol: record.completed ? "checkmark.circle" : "circle",
                        accent: .movement
                    )
                }

                RouteGraphicCollection(record: record, identifier: graphicIdentifier)

                LooprText(
                    "Location is shown only because this route was explicitly recorded.",
                    style: .prose,
                    color: .inkSecondary
                )
            }
        }
    }
}

private struct RouteGraphicCollection: View {
    let record: RouteRecord
    let identifier: String?
    @Environment(\.looprMeasurementSystem) private var measurementSystem

    private var primitive: RoutePrimitiveData { RoutePrimitiveData(route: record) }

    var body: some View {
        ForEach(Array(primitive.polylines.enumerated()), id: \.offset) { index, polyline in
            routeGraphic(polyline, index: index)
        }
    }

    @ViewBuilder
    private func routeGraphic(_ polyline: [RoutePoint], index: Int) -> some View {
        let distance = LooprUnitFormatter.distance(
            meters: RouteMath.distanceMeters(route: record),
            system: measurementSystem
        )
        let graphic = RouteGraphic(
            coordinates: polyline.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            },
            distance: distance.combined,
            duration: routeDurationPresentation(RouteMath.duration(route: record))
        )
        .aspectRatio(1.35, contentMode: .fit)
        .saturation(0.35)
        .overlay {
            RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous)
                .strokeBorder(Color.loopr(.divider), lineWidth: LooprSpacing.hairline)
                .padding(LooprSpacing.hairline)
                .allowsHitTesting(false)
        }

        if let identifier {
            graphic.accessibilityIdentifier(index == 0 ? identifier : "\(identifier)-\(index)")
        } else {
            graphic
        }
    }
}

private struct RouteSummarySection: View {
    let record: RouteRecord
    @Environment(\.looprMeasurementSystem) private var measurementSystem

    var body: some View {
        LooprSectionGroup(title: "Route summary") {
            HairlineMetricList(rows: routeSummaryRows(record: record, system: measurementSystem))
        }
    }
}

private struct RouteZoneChartSection: View {
    let zones: [ZoneSample]

    var body: some View {
        LooprSectionGroup(title: "Heart rate zones") {
            LooprSurface {
                ZoneChart(zones: zones)
            }
        }
    }
}

private struct RouteSegmentMetricList: View {
    let segments: [RouteSegment]

    var body: some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(spacing: LooprSpacing.none) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    HairlineMetricRow(
                        id: "route-zone-segment-\(index)",
                        title: segment.zone.map { "Zone \($0)" } ?? "Zone not assigned",
                        confidence: segment.startsAfterGap ? "AFTER GPS GAP" : nil,
                        value: String(segment.points.count),
                        unit: "points"
                    )
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .accessibilityIdentifier("route-zone-segment-\(index)")

                    if index < segments.count - 1 {
                        LooprHairline()
                    }
                }
            }
        }
    }
}

private struct RouteNoGPSSurface: View {
    var body: some View {
        LooprSurface(emphasis: .hero(.movement)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                StateMessage(.absent)
                LooprInlineMessage(
                    "GPS was not recorded for this workout.",
                    tone: .neutral
                )
            }
        }
    }
}

private struct RouteStateSurface: View {
    let state: MetricState
    var message: String?
    var retry: (() -> Void)? = nil

    var body: some View {
        LooprSurface(emphasis: .hero(.movement)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                StateMessage(state)
                if let message {
                    LooprInlineMessage(message, tone: .critical)
                }
                if state == .recoverableError, let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(LooprButtonStyle(prominent: false))
                        .accessibilityIdentifier("route-retry")
                }
            }
        }
    }
}

private struct RouteLoadingSurface: View {
    var body: some View {
        LooprSurface(emphasis: .hero(.movement)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                StateMessage(.loading, compact: true)
                LooprSkeleton(height: LooprSpacing.hero * 4)
            }
        }
    }
}

private struct RouteSharePreviewPanel: View {
    let record: RouteRecord
    let exporter: any RouteExporter

    @Environment(\.looprMeasurementSystem) private var measurementSystem
    @State private var includeLocation = false
    @State private var preview: RouteExportPayload?
    @State private var errorMessage: String?
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            if !record.hasUsableGPS {
                RouteNoGPSSurface()
            }

            LooprSectionGroup(title: "Workout") {
                HairlineMetricList(rows: routeShareRows(record: record, system: measurementSystem))
            }

            LooprSectionGroup(title: "Share settings") {
                LooprFormCard(padding: LooprSpacing.none) {
                    LooprToggleRow(
                        title: "Include location",
                        subtitle: "Adds the recorded coordinates to the exported file.",
                        isOn: $includeLocation
                    )
                }
            }

            Button(isCreating ? "Creating preview" : "Create route preview") {
                isCreating = true
                errorMessage = nil
                Task { @MainActor in
                    do {
                        preview = try await exporter.export(
                            route: record,
                            request: RouteExportRequest(includeLocation: includeLocation)
                        )
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isCreating = false
                }
            }
            .buttonStyle(LooprPrimaryButtonStyle())
            .disabled(isCreating)
            .accessibilityIdentifier("route-share-create")

            if isCreating {
                LooprFormCard {
                    StateMessage(.loading, compact: true)
                }
            }

            if let preview {
                LooprSectionGroup(title: "Ready to review") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText("Workout route preview", style: .cardTitle)
                                .accessibilityIdentifier("route-share-summary")
                            LooprInlineMessage("Route preview prepared locally.", tone: .positive)
                            HairlineMetricList(rows: routePreviewRows(preview))
                        }
                    }
                }
            }

            if let errorMessage {
                LooprFormCard {
                    LooprInlineMessage(errorMessage, tone: .critical)
                        .accessibilityIdentifier("route-share-error")
                }
            }
        }
    }
}

private func routeSummaryRows(
    record: RouteRecord,
    system: LooprMeasurementSystem
) -> [HairlineMetricRow] {
    let distance = LooprUnitFormatter.distance(
        meters: RouteMath.distanceMeters(route: record),
        system: system
    )
    return [
        HairlineMetricRow(
            id: "route-summary-distance",
            title: "Distance",
            value: distance.value,
            unit: distance.unit
        ),
        HairlineMetricRow(
            id: "route-summary-duration",
            title: "Duration",
            value: routeDurationPresentation(RouteMath.duration(route: record)),
            unit: "elapsed"
        ),
        HairlineMetricRow(
            id: "route-summary-points",
            title: "Location points",
            value: String(record.points.count),
            unit: "points"
        )
    ]
}

private func routeShareRows(
    record: RouteRecord,
    system: LooprMeasurementSystem
) -> [HairlineMetricRow] {
    guard record.hasUsableGPS else {
        return [
            HairlineMetricRow(
                id: "route-share-route",
                title: "Route",
                value: MetricState.absent.title
            )
        ]
    }
    return routeSummaryRows(record: record, system: system)
}

private func routePreviewRows(_ preview: RouteExportPayload) -> [HairlineMetricRow] {
    [
        HairlineMetricRow(
            id: "route-share-location",
            title: "Location",
            value: preview.includesLocation ? "Included" : "Excluded"
        ),
        HairlineMetricRow(
            id: "route-share-points",
            title: "Route points",
            value: preview.includesLocation ? String(preview.points.count) : "Redacted",
            unit: preview.includesLocation ? "points" : nil
        )
    ]
}

private func routeSplitRows(for splits: [RouteSplit]) -> [HairlineMetricRow] {
    splits.enumerated().map { index, split in
        HairlineMetricRow(
            id: "route-split-\(index)",
            title: "Split \(index + 1)",
            confidence: split.zone.map { "ZONE \($0)" },
            value: routeDurationPresentation(split.duration),
            unit: "elapsed"
        )
    }
}

private func zoneSamples(for record: RouteRecord) -> [ZoneSample] {
    record.segments.enumerated().compactMap { index, segment in
        guard let zone = segment.zone,
              let start = segment.points.first?.timestamp,
              let end = segment.points.last?.timestamp,
              end > start else {
            return nil
        }
        return ZoneSample(
            id: index,
            name: "Zone \(zone)",
            minutes: end.timeIntervalSince(start) / 60,
            symbol: String(zone)
        )
    }
}

private func routeDurationPresentation(_ duration: TimeInterval?) -> String {
    routeDurationPresentation(duration ?? 0)
}

private func routeDurationPresentation(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
    }
    return "\(minutes):\(String(format: "%02d", seconds))"
}

private extension RouteRecord {
    var hasUsableGPS: Bool { points.count > 1 }
}

private extension RouteScreenSnapshot.State {
    var metricState: MetricState {
        switch self {
        case .loading: .loading
        case .noRecords: .noRecords
        case .absent: .absent
        case .measuredZero: .measuredZero
        case .partial: .partial
        case .lowConfidence: .lowConfidence
        case .settling: .settling
        case .stale: .stale
        case .disconnected: .disconnected
        case .bluetoothOff: .bluetoothOff
        case .permissionDenied: .permissionDenied
        case .unsupportedHardware: .unsupportedHardware
        case .recoverableError, .migrationFailure: .recoverableError
        case .destructiveFailure: .destructiveFailure
        case .ready: .absent
        }
    }

    var isError: Bool {
        switch self {
        case .recoverableError, .destructiveFailure, .migrationFailure: true
        default: false
        }
    }
}
