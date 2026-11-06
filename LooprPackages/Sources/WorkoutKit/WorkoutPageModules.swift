import AnalyticsKit
import Charts
import DesignSystem
import MapKit
import SwiftUI

/// The route on a small map. A tap opens the full route.
struct WorkoutPageMapCard: View {
    let route: WorkoutPageRoute
    let open: () -> Void

    var body: some View {
        LooprSectionGroup(title: "Route") {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Button(action: open) {
                        Map(interactionModes: []) {
                            ForEach(Array(route.segments.enumerated()), id: \.offset) { _, segment in
                                MapPolyline(coordinates: segment.map(Self.coordinate))
                                    .stroke(Color.loopr(.movement), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            }
                            if let first = route.segments.first?.first {
                                Annotation("Start", coordinate: Self.coordinate(first), anchor: .center) { pin(.recovery) }
                            }
                            if let last = route.segments.last?.last {
                                Annotation("Finish", coordinate: Self.coordinate(last), anchor: .center) { pin(.ink) }
                            }
                        }
                        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                        .allowsHitTesting(false)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Route map. Opens the full route.")
                    .accessibilityIdentifier("workout-page-map")
                    if route.gapSeconds >= 60 {
                        LooprText("No GPS for \(Int(route.gapSeconds / 60)) min. The line stops there, and the distance leaves it out.",
                                  style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("workout-page-gps-gap")
                    }
                    if route.elapsedSeconds - route.movingSeconds - route.gapSeconds >= 60 {
                        LooprText("Stopped for \(Int((route.elapsedSeconds - route.movingSeconds - route.gapSeconds) / 60)) min. Moving time leaves it out.",
                                  style: .caption, color: .inkSecondary)
                    }
                    LooprText("Location is shown only because this route was explicitly recorded.", style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func pin(_ token: LooprColorToken) -> some View {
        Circle().fill(Color.loopr(token)).frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
    }

    private static func coordinate(_ value: WorkoutPageRoute.Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude)
    }
}

/// One row per kilometre or mile: a bar for the pace, the pace, heart rate and climb.
struct WorkoutPageSplitsCard: View {
    let route: WorkoutPageRoute
    let activity: ActivityType
    let system: LooprMeasurementSystem

    var body: some View {
        let full = route.splits.filter { !$0.isPartial }
        let fastest = full.map(\.secondsPerKilometer).min()
        let slowest = route.splits.map(\.secondsPerKilometer).max() ?? 1
        LooprSectionGroup(title: "Splits") {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    ForEach(route.splits) { split in
                        HStack(spacing: LooprSpacing.xs) {
                            LooprText(label(split), style: .caption, color: .inkSecondary)
                                .frame(minWidth: 30, alignment: .leading)
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(Color.loopr(.movement).opacity(split.secondsPerKilometer == fastest ? 1 : 0.35))
                                    // A faster stretch draws a longer bar.
                                    .frame(width: max(8, geometry.size.width * (fastest ?? slowest) / max(split.secondsPerKilometer, 1)))
                            }
                            .frame(height: 8)
                            LooprValueText(speed(split).value, unit: speed(split).unit)
                                .frame(minWidth: 86, alignment: .trailing)
                            LooprText(split.averageBPM.map { "\($0)" } ?? "--", style: .caption, color: .inkSecondary)
                                .frame(minWidth: 28, alignment: .trailing)
                            if route.ascentMeters != nil {
                                LooprText(split.climbMeters.map { "+\(Int($0.rounded()))" } ?? "--", style: .caption, color: .inkSecondary)
                                    .frame(minWidth: 30, alignment: .trailing)
                            }
                        }
                        .frame(minHeight: 28)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("workout-page-split-\(split.number)")
                    }
                    LooprText(route.ascentMeters == nil ? "Pace, then average bpm." : "Pace, then average bpm and metres climbed.", style: .caption, color: .inkSecondary)
                }
            }
        }
    }

    private func label(_ split: WorkoutPageRoute.Split) -> String {
        guard split.isPartial else { return "\(split.number)" }
        return LooprUnitFormatter.distance(meters: split.meters, system: system).combined
    }

    private func speed(_ split: WorkoutPageRoute.Split) -> (value: String, unit: String?) {
        guard let companion = WorkoutPagePresentation.speedCompanion(activity: activity, meters: split.meters, seconds: split.seconds, system: system) else {
            return ("--", nil)
        }
        return (companion.value, companion.unit)
    }
}

struct WorkoutPageElevationCard: View {
    let route: WorkoutPageRoute

    var body: some View {
        LooprSectionGroup(title: "Elevation") {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HStack(spacing: LooprSpacing.lg) {
                        if let up = route.ascentMeters { stat("Up", up) }
                        if let down = route.descentMeters { stat("Down", down) }
                        if let top = route.highestMeters { stat("Highest", top) }
                    }
                    let low = (route.elevation.map(\.altitude).min() ?? 0)
                    Chart(route.elevation) { point in
                        AreaMark(x: .value("Distance", point.meters), yStart: .value("Floor", low), yEnd: .value("Altitude", point.altitude))
                            .foregroundStyle(Color.loopr(.movement).opacity(0.25))
                        LineMark(x: .value("Distance", point.meters), y: .value("Altitude", point.altitude))
                            .foregroundStyle(Color.loopr(.movement))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .chartYScale(domain: low...max(low + 10, route.elevation.map(\.altitude).max() ?? low + 10))
                    .frame(height: 96)
                    .accessibilityHidden(true)
                    LooprText("From GPS altitude, smoothed.", style: .caption, color: .inkSecondary)
                }
            }
        }
        .accessibilityIdentifier("workout-page-elevation")
    }

    private func stat(_ label: String, _ meters: Double) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            LooprText(label, style: .caption, color: .inkSecondary)
            LooprValueText("\(Int(meters.rounded()))", unit: "m")
        }
        .accessibilityElement(children: .combine)
    }
}

/// One row per effort: its peak and how far heart rate fell in the next minute.
struct WorkoutPageEffortsCard: View {
    let analysis: WorkoutSessionAnalysis

    var body: some View {
        LooprSectionGroup(title: "Efforts") {
            LooprSurface {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    ForEach(analysis.efforts) { effort in
                        HStack(spacing: LooprSpacing.sm) {
                            LooprText("\(effort.number)", style: .rowTitle).frame(minWidth: 20, alignment: .leading)
                            if !analysis.effortsAreFound {
                                LooprText(Self.time(effort.seconds), style: .caption, color: .inkSecondary)
                            }
                            Spacer(minLength: LooprSpacing.xs)
                            LooprValueText("\(effort.peakBPM)", unit: "bpm")
                            LooprText(effort.dropBPM.map { "\($0 >= 0 ? "−" : "+")\(abs($0)) in 1 min" } ?? "No reading after",
                                      style: .caption, color: .inkSecondary)
                                .frame(minWidth: 84, alignment: .trailing)
                        }
                        .frame(minHeight: 28)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("workout-page-effort-\(effort.number)")
                    }
                    if analysis.effortsAreFound {
                        LooprText("Found in heart rate. \(WorkoutSessionAnalysis.effortRule)", style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        LooprText("From the interval timer. Peak heart rate, then the fall in the minute after it.", style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// A tap says how hard it felt. It is the one thing nothing else can measure, so it is one tap away.
struct WorkoutPageHowHardCard: View {
    let workout: WorkoutRecord
    let save: (Int?) async throws -> Void
    /// Opens the editor, for what this type can add: lengths, calories, a note.
    let edit: (() -> Void)?
    @State private var errorMessage: String?

    var body: some View {
        LooprSectionGroup(title: "How it felt") {
            LooprFormCard(padding: LooprSpacing.none) {
                VStack(spacing: LooprSpacing.none) {
                    WorkoutEffortPicker(effort: Binding(get: { workout.effort }, set: { value in store(value) }),
                                        identifier: "workout-page-effort")
                    if let edit, let addTitle {
                        LooprHairline()
                        Button(addTitle, action: edit)
                            .buttonStyle(LooprButtonStyle(prominent: false, accent: .workoutAccent))
                            .padding(LooprSpacing.sm)
                            .accessibilityIdentifier("workout-page-add")
                    }
                    if let errorMessage {
                        LooprInlineMessage(errorMessage, tone: .warning)
                    }
                }
            }
        }
    }

    private var addTitle: String? {
        if workout.activity.takesLengths, workout.lengths == nil { return "Add lengths" }
        if workout.activity.takesCalories, workout.loggedCalories == nil { return "Add what the machine says" }
        if workout.activity.recordsRoute, workout.resolvedDistanceMeters == nil { return "Add distance" }
        return workout.notes == nil ? "Add a note" : nil
    }

    private func store(_ value: Int?) {
        errorMessage = nil
        Task { @MainActor in
            do { try await save(value) } catch { errorMessage = error.localizedDescription }
        }
    }
}

/// Totals from a WHOOP account export. These are the export's numbers, labelled with where they came from.
struct WorkoutPageImportedCard: View {
    let summary: WorkoutImportedSummary

    var body: some View {
        LooprSectionGroup(title: summary.source) {
            HairlineMetricList(rows: rows)
        }
    }

    private var rows: [HairlineMetricRow] {
        let definitions: [(String, String, Double?, String)] = [
            ("strain", "Strain", summary.strain, "/21"),
            ("energy", "Energy", summary.energyKcal, "kcal"),
            ("average", "Average heart rate", summary.averageHeartRate, "bpm"),
            ("maximum", "Maximum heart rate", summary.maximumHeartRate, "bpm")
        ]
        var rows = definitions.map { id, title, value, unit in
            HairlineMetricRow(id: "import-" + id, title: title,
                value: value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "Not recorded", unit: value == nil ? nil : unit,
                accent: .movement)
        }
        for zone in summary.zonePercentages.keys.sorted() {
            rows.append(HairlineMetricRow(id: "import-zone-\(zone)", title: "Zone \(zone)",
                value: summary.zonePercentages[zone]!.formatted(.number.precision(.fractionLength(0...1))), unit: "%", accent: .movement))
        }
        return rows
    }
}
