#if DEBUG
import SharedSurfaceKit
import SwiftUI
import WidgetKit

enum LooprNativeSurfaceCandidateMode {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[LooprNativeSurfaceProbe.environmentKey] == "candidates"
    }
}

struct LooprNativeSurfaceCandidateRoot: View {
    private let now = Date(timeIntervalSinceReferenceDate: 810_000_000)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Native candidate validation")
                    .font(.title2.weight(.bold))

                candidateRow("Today small") {
                    widgetCandidate(
                        title: "Today",
                        family: .systemSmall,
                        projection: SurfaceWidgetProjection.today(
                            snapshot: snapshot,
                            now: now
                        )
                    )
                    .frame(width: 150, height: 150)
                    .accessibilityIdentifier("native-candidate-today-system-small")
                }

                candidateRow("Today medium") {
                    widgetCandidate(
                        title: "Today",
                        family: .systemMedium,
                        projection: SurfaceWidgetProjection.today(
                            snapshot: snapshot,
                            now: now
                        )
                    )
                    .frame(width: 310, height: 140)
                    .accessibilityIdentifier("native-candidate-today-system-medium")
                }

                candidateRow("Today rectangular") {
                    widgetCandidate(
                        title: "Today",
                        family: .accessoryRectangular,
                        projection: SurfaceWidgetProjection.today(
                            snapshot: snapshot,
                            now: now,
                            privacy: .lockScreen
                        )
                    )
                    .frame(width: 180, height: 64)
                    .accessibilityIdentifier("native-candidate-today-accessory-rectangular")
                }

                candidateRow("Today inline") {
                    widgetCandidate(
                        title: "Today",
                        family: .accessoryInline,
                        projection: SurfaceWidgetProjection.today(
                            snapshot: snapshot,
                            now: now,
                            privacy: .lockScreen
                        )
                    )
                    .frame(width: 300, height: 30)
                    .accessibilityIdentifier("native-candidate-today-accessory-inline")
                }

                candidateRow("Band circular") {
                    widgetCandidate(
                        title: "Band",
                        family: .accessoryCircular,
                        projection: SurfaceWidgetProjection.battery(
                            snapshot: snapshot,
                            now: now,
                            privacy: .lockScreen
                        )
                    )
                    .frame(width: 72, height: 72)
                    .accessibilityIdentifier("native-candidate-band-accessory-circular")
                }

                candidateRow("Band small") {
                    widgetCandidate(
                        title: "Band",
                        family: .systemSmall,
                        projection: SurfaceWidgetProjection.battery(
                            snapshot: snapshot,
                            now: now
                        )
                    )
                    .frame(width: 150, height: 150)
                    .accessibilityIdentifier("native-candidate-band-system-small")
                }

                candidateRow("Band rectangular") {
                    widgetCandidate(
                        title: "Band",
                        family: .accessoryRectangular,
                        projection: SurfaceWidgetProjection.battery(
                            snapshot: snapshot,
                            now: now,
                            privacy: .lockScreen
                        )
                    )
                    .frame(width: 180, height: 64)
                    .accessibilityIdentifier("native-candidate-band-accessory-rectangular")
                }

                candidateRow("Band inline") {
                    widgetCandidate(
                        title: "Band",
                        family: .accessoryInline,
                        projection: SurfaceWidgetProjection.battery(
                            snapshot: snapshot,
                            now: now,
                            privacy: .lockScreen
                        )
                    )
                    .frame(width: 300, height: 30)
                    .accessibilityIdentifier("native-candidate-band-accessory-inline")
                }

                HStack(spacing: 28) {
                    minimalCandidate(
                        title: "Workout minimal",
                        visual: .workout(
                            activityName: "Run",
                            elapsedSeconds: 180,
                            heartRate: 132,
                            status: "Active"
                        ),
                        identifier: "native-candidate-workout-minimal"
                    )
                    minimalCandidate(
                        title: "Breathing minimal",
                        visual: .breathing(completedCycles: 3, status: "In progress"),
                        identifier: "native-candidate-breathing-minimal"
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("native-surface-candidate-root")
    }

    private func candidateRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 112, alignment: .leading)
            content()
        }
    }

    private func widgetCandidate(
        title: String,
        family: WidgetFamily,
        projection: SurfaceWidgetEntry
    ) -> some View {
        LooprWidgetContent(title: title, projection: projection, family: family)
            .padding(family == .accessoryInline ? 4 : 8)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func minimalCandidate(
        title: String,
        visual: LooprLiveActivityVisual,
        identifier: String
    ) -> some View {
        VStack(spacing: 6) {
            LooprMinimalLiveActivityCandidate(visual: visual)
                .accessibilityIdentifier(identifier)
            Text(title)
                .font(.caption2)
                .accessibilityHidden(true)
        }
    }

    private var snapshot: SurfaceSnapshot {
        SurfaceSnapshot(
            generation: 810,
            createdAt: now,
            sourceDay: SurfaceDayLabel.format(now),
            syncDate: now,
            metrics: .init(recovery: 82, strain: 8.6, heartRate: 54, sleepMinutes: 462),
            battery: .init(level: 0.74, observedAt: now),
            activeWorkout: nil,
            staleReasons: []
        )
    }
}
#endif
