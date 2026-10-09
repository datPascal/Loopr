import DesignSystem
import DeviceCenterKit
import Foundation
import RouteKit
import StressKit
import SwiftUI
import WorkoutKit

/// Actions use the runtime handle and canonical repositories already owned by
/// the app. No action creates a Bluetooth transport or command writer.
@MainActor
final class LooprHandsFreeRuntime {
    static let shared = LooprHandsFreeRuntime()
    weak var repositories: ProductRepositoryContainer?

    func stopBreathingForDeletion() async {
        if let breathing = repositories?.persistent?.breathingSession {
            await breathing.invalidateGeneration()
        }
    }

    func context() async throws -> ProductRepositoryContainer {
        // Intents open the app. Let its shell attach the canonical graph on a
        // cold launch rather than opening a second set of repositories.
        for _ in 0..<30 {
            if let repositories {
                guard repositories.persistent != nil else { throw HandsFreeError.storage }
                return repositories
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HandsFreeError.openApp
    }

    func syncBand() async throws -> Bool {
        guard let model = LooprLaunchBootstrap.shared.model else { throw HandsFreeError.openApp }
        await model.inspectProvisioningOnLaunch()
        return await model.runtimeHandle.performManualSync(maxDuration: 30)
    }

    func buzzBand() async throws {
        guard let model = LooprLaunchBootstrap.shared.model else { throw HandsFreeError.openApp }
        await model.inspectProvisioningOnLaunch()
        // OpenStrap documentation, edge/guides/BUZZ_MEANINGS.md: effect 0 is
        // a quick single cue. Effect 1 latches, so it is never used here.
        try await model.runtimeHandle.buzzBand(effect: BandCuePattern.single)
    }

    func markMoment() async throws {
        guard let journal = try await context().persistent?.journal else { throw HandsFreeError.storage }
        // Use the same canonical journal sink as the double-tap action. This
        // local action does not require a Bluetooth connection generation.
        let sink = LooprJournalMomentSink(journal: journal, note: "Marked from Shortcuts")
        try await sink.mark(at: Date())
    }

    func exportLastWorkoutRoute() async throws -> GPXRouteFile {
        let context = try await context()
        guard let store = context.workoutStore, let routes = context.persistent?.routes else { throw HandsFreeError.storage }
        guard let workout = await store.all().filter({ $0.state == .completed }).max(by: {
            ($0.endedAt ?? $0.createdAt) < ($1.endedAt ?? $1.createdAt)
        }), let route = try await routes.route(workoutID: workout.id.uuidString), !route.points.isEmpty else { throw HandsFreeError.noRoute }
        return try LocalRouteExporter().gpx(route: route, name: workout.activity.displayName, samples: workout.samples)
    }
}

nonisolated enum HandsFreeError: LocalizedError {
    case openApp, storage, noRoute
    var errorDescription: String? {
        switch self {
        case .openApp: "Open Loopr and try again."
        case .storage: "Loopr could not open your saved data."
        case .noRoute: "Your last workout has no recorded route."
        }
    }
}

/// Resolves the route on the detail screen even before an export row exists.
/// The app injects the ShareLink into the package's Actions card.
struct WorkoutGPXShareAction: ViewModifier {
    let workout: WorkoutRecord
    let routes: (any RouteStore)?
    @State private var file: GPXRouteFile?

    func body(content: Content) -> some View {
        content
            .environment(\.workoutRouteExport, file.map { file in
                AnyView(
                    ShareLink(item: file, preview: SharePreview("Workout route")) {
                        HStack(spacing: LooprSpacing.sm) {
                            LooprText("Export route as GPX", style: .settingsRow)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: LooprSpacing.sm)
                            Image(systemName: "square.and.arrow.up")
                                .looprTypography(.label)
                                .foregroundStyle(Color.loopr(.inkMuted))
                        }
                        .padding(.horizontal, LooprSpacing.formCardPadding)
                        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.looprPressableRow)
                    .accessibilityLabel("Export route as GPX")
                    .accessibilityIdentifier("workout-share-gpx")
                )
            })
            .task(id: workout.id) {
                file = nil
                var stored = try? await routes?.route(workoutID: workout.id.uuidString)
                #if DEBUG
                if stored == nil, routes == nil, DebugCaptureFixtures.gpxRoute { stored = DebugCaptureFixtures.fixtureRoute }
                #endif
                guard let route = stored, !route.points.isEmpty else { return }
                file = try? LocalRouteExporter().gpx(route: route, name: workout.activity.displayName, samples: workout.samples)
            }
    }
}
