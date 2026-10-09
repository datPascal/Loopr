import DomainKit
import Foundation
import JournalKit

enum AppHabitFeatureGate {
    static let infoDictionaryKey = "LooprHabitInsightsStage"

    static var currentStage: HabitFeatureStage {
        stage(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func stage(infoDictionary: [String: Any]) -> HabitFeatureStage {
        if let rawValue = infoDictionary[infoDictionaryKey] as? String,
           let configured = HabitFeatureStage(rawValue: rawValue) {
            return configured
        }
        #if DEBUG
        return .internalOnly
        #else
        return .disabled
        #endif
    }
}

public struct AppEnvironment: Sendable {
    public enum Root: String, Sendable { case onboarding, main }
    public enum Composition: String, Sendable { case production, onboarding, pairing, empty, populated, stale, disconnected, activeWorkout, connectedMixedCapabilities }

    public let composition: Composition
    public let root: Root
    /// The single local SQLite file used by production product repositories.
    /// Fixture compositions intentionally leave this nil so DEBUG launch modes
    /// cannot accidentally mutate a user's durable store.
    public let storageURL: URL?
    public let applicationVersion: String
    let dateProvider: any DateProviding
    let calendarProvider: any CalendarProviding
    let timeZoneProvider: any TimeZoneProviding
    let uuidProvider: any UUIDProviding
    let scheduler: any Scheduling

    public static func make(arguments: [String] = ProcessInfo.processInfo.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        #if DEBUG
        if let mode = LaunchModeParser.parse(arguments: arguments, environment: environment) { return fixture(mode) }
        #endif
        return production()
    }

    public static func production() -> Self {
        Self(
            composition: .production,
            root: .onboarding,
            storageURL: applicationSupportDatabaseURL(),
            applicationVersion: bundleApplicationVersion(),
            dateProvider: SystemDateProvider(),
            calendarProvider: SystemCalendarProvider(),
            timeZoneProvider: SystemTimeZoneProvider(),
            uuidProvider: SystemUUIDProvider(),
            scheduler: SystemScheduler()
        )
    }

    #if DEBUG
    /// First-launch onboarding with nothing persisted, for replaying it from
    /// Settings. Real clocks, but no storage URL, so the flow runs on
    /// in-memory repositories and cannot touch the user's store or pairing.
    static func onboardingReplay() -> Self {
        Self(
            composition: .onboarding,
            root: .onboarding,
            storageURL: nil,
            applicationVersion: bundleApplicationVersion(),
            dateProvider: SystemDateProvider(),
            calendarProvider: SystemCalendarProvider(),
            timeZoneProvider: SystemTimeZoneProvider(),
            uuidProvider: SystemUUIDProvider(),
            scheduler: SystemScheduler()
        )
    }

    private static func fixture(_ mode: LaunchMode) -> Self {
        let composition = Composition(rawValue: mode.rawValue)!
        let root: Root = mode == .onboarding || mode == .pairing ? .onboarding : .main
        return Self(
            composition: composition,
            root: root,
            storageURL: nil,
            applicationVersion: "DEBUG Fixture",
            dateProvider: FixedDateProvider(),
            calendarProvider: SystemCalendarProvider(),
            timeZoneProvider: FixedTimeZoneProvider(),
            uuidProvider: FixedUUIDProvider(),
            scheduler: SystemScheduler()
        )
    }
#endif

    func productDay(fixture: DayIdentity) -> DayIdentity {
        guard composition == .production else { return fixture }
        let components = calendarProvider.components(in: timeZoneProvider.timeZone, from: dateProvider.now())
        return DayIdentity(era: components.era ?? 1, year: components.year!, month: components.month!, day: components.day!)
    }

    private static func applicationSupportDatabaseURL() -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return directory.appendingPathComponent("Loopr.sqlite", isDirectory: false)
    }

    private static func bundleApplicationVersion() -> String {
        let marketing = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        if let marketing, let build { return "\(marketing) (\(build))" }
        return marketing ?? build ?? "0.1 (0)"
    }
}

#if DEBUG
private struct FixedDateProvider: DateProviding {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}
private struct FixedTimeZoneProvider: TimeZoneProviding { let timeZone = TimeZone(secondsFromGMT: 0)! }
private actor FixedUUIDProvider: UUIDProviding {
    func nextUUID() -> UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
}
#endif
