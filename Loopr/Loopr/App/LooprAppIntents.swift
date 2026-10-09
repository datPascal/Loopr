#if canImport(AppIntents)
import AppIntents
import Foundation
import UniformTypeIdentifiers
import SharedSurfaceKit
import RouteKit

private nonisolated enum IntentSnapshotReader {
    static func read() -> SurfaceSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SurfaceConfiguration.appGroupIdentifier
        ) else { return nil }
        return try? SurfaceSnapshotCodec.decode(
            Data(contentsOf: container.appendingPathComponent("surface.json"))
        )
    }
}

struct LooprRecoveryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Recovery"
    static let description = IntentDescription("Read your latest recovery from Loopr.")

    nonisolated static func dialog(snapshot: SurfaceSnapshot?, now: Date) -> String {
        SurfaceTodayReading.dialog(.recovery, snapshot: snapshot, now: now)
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Self.dialog(snapshot: IntentSnapshotReader.read(), now: .now)))
    }
}

struct LooprSleepIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Sleep"
    static let description = IntentDescription("Read last night's sleep duration and sleep need from Loopr.")
    nonisolated static func dialog(snapshot: SurfaceSnapshot?, now: Date) -> String {
        SurfaceTodayReading.dialog(.sleep, snapshot: snapshot, now: now)
    }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Self.dialog(snapshot: IntentSnapshotReader.read(), now: .now)))
    }
}

struct LooprStrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Strain"
    static let description = IntentDescription("Read today's strain from Loopr.")
    nonisolated static func dialog(snapshot: SurfaceSnapshot?, now: Date) -> String {
        SurfaceTodayReading.dialog(.strain, snapshot: snapshot, now: now)
    }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: Self.dialog(snapshot: IntentSnapshotReader.read(), now: .now)))
    }
}

struct OpenLooprTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Loopr Today"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "loopr://today")!))
    }
}

struct OpenLooprBreathingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Breathing"
    static let description = IntentDescription("Start a breathing session with optional band buzzes.")
    static let openAppWhenRun = true
    @Parameter(title: "Pace with band buzzes", default: false)
    var paceWithBand: Bool

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "loopr://breathing?start=true&band=\(paceWithBand)")!))
    }
}

struct LooprSyncBandIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Band"
    static let description = IntentDescription("Sync recent data from your connected band.")
    static let openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let complete = try await LooprHandsFreeRuntime.shared.syncBand()
        return .result(dialog: complete ? "Band sync finished." : "Sync did not finish. Connect your band and try again.")
    }
}

struct LooprBuzzBandIntent: AppIntent {
    static let title: LocalizedStringResource = "Buzz Band"
    static let description = IntentDescription("Send a short buzz to your connected band.")
    static let openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await LooprHandsFreeRuntime.shared.buzzBand()
        return .result(dialog: "Buzz sent.")
    }
}

struct LooprMarkMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Moment"
    static let description = IntentDescription("Save the current time as a moment in your journal.")
    static let openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await LooprHandsFreeRuntime.shared.markMoment()
        return .result(dialog: "Moment saved.")
    }
}

struct LooprExportLastRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Last Workout Route"
    static let description = IntentDescription("Export your last workout's recorded route as a GPX file.")
    static let openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let file = try await LooprHandsFreeRuntime.shared.exportLastWorkoutRoute()
        return .result(value: IntentFile(data: file.data, filename: file.filename, type: .looprGPX))
    }
}

struct LooprShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LooprRecoveryIntent(),
            phrases: ["Check my recovery in \(.applicationName)"],
            shortTitle: "Check Recovery",
            systemImageName: "heart.text.square"
        )
        AppShortcut(intent: LooprSleepIntent(), phrases: ["Check my sleep in \(.applicationName)"], shortTitle: "Check Sleep", systemImageName: "moon.fill")
        AppShortcut(intent: LooprStrainIntent(), phrases: ["Check my strain in \(.applicationName)"], shortTitle: "Check Strain", systemImageName: "figure.strengthtraining.traditional")
        AppShortcut(
            intent: OpenLooprTodayIntent(),
            phrases: ["Open Today in \(.applicationName)"],
            shortTitle: "Open Today",
            systemImageName: "chart.bar"
        )
        AppShortcut(
            intent: OpenLooprBreathingIntent(),
            phrases: ["Start breathing in \(.applicationName)"],
            shortTitle: "Start Breathing",
            systemImageName: "wind"
        )
        AppShortcut(intent: LooprSyncBandIntent(), phrases: ["Sync my band with \(.applicationName)"], shortTitle: "Sync Band", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: LooprBuzzBandIntent(), phrases: ["Buzz my band with \(.applicationName)"], shortTitle: "Buzz Band", systemImageName: "waveform")
        AppShortcut(intent: LooprMarkMomentIntent(), phrases: ["Mark a moment in \(.applicationName)"], shortTitle: "Mark Moment", systemImageName: "bookmark")
        AppShortcut(intent: LooprExportLastRouteIntent(), phrases: ["Export my last workout route from \(.applicationName)"], shortTitle: "Export Route", systemImageName: "map")
    }
}
#endif
