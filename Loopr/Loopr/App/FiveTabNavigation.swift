import AnalyticsKit
import BodyKit
import DataKit
import DesignSystem
import HeartKit
import RecordsKit
import SleepKit
import StressKit
import SwiftUI

/// The five tabs in tab bar order (DEC-12.1): Today, Food, Fitness, Protocol, Data.
///
/// Three raw values are the strings build 21 saved under `selectionKey` when the tabs were named
/// train, journal and health. They stay as they are forever, so a saved selection restores with
/// no migration. `restoring` also accepts the new names.
nonisolated enum MainTab: String, CaseIterable, Hashable, Sendable {
    case today, food
    case fitness = "train"
    case `protocol` = "journal"
    case data = "health"
    static let selectionKey = "loopr.shell.selected-tab.v1"
    var title: String {
        switch self {
        case .today: "Today"
        case .food: "Food"
        case .fitness: "Fitness"
        case .protocol: "Protocol"
        case .data: "Data"
        }
    }
    /// An SF Symbol name, or an image asset name when `symbolIsAsset` is true.
    var symbol: String {
        switch self {
        case .today: "clock"
        case .food: "fork.knife"
        case .fitness: "dumbbell"
        case .protocol: "ProtocolRosette"
        case .data: "chart.bar"
        }
    }
    /// Protocol's rosette has no SF Symbol. It is a template image in the asset catalog.
    var symbolIsAsset: Bool { self == .protocol }
    var accent: LooprColorToken {
        switch self {
        case .today: .brand
        case .food: .energy
        case .fitness: .strain
        case .protocol: .protocol
        case .data: .brand
        }
    }
}

enum AppHealthRoute: Hashable {
    case sleepHome, heartHome, bodyHome, stressHome, allMetrics
    /// Weight and body composition, typed in or read from Apple Health. Opens from the Body screen.
    case bodyLog
    /// Body: weight, body composition and cardio fitness. Strain has its own page, `bodyHome` (Data ICP R1).
    case bodyMeasures
    /// Personal bests, then streaks, journey, timeline and recaps from there.
    case recordsHome
    case records(RecordsRoute)
    case sleep(SleepRoute)
    case heart(AppHeartRoute)
    case body(BodyRoute)
    case stress(StressRoute)
    /// One metric's detail page, pushed straight from an Ask source.
    case metric(MetricKey)
    /// Your data, pushed on Data's stack by the band button while Data is the selected tab (DEC-12.1).
    case yourData
    /// A screen Your data opens (a provider, export, deletion or Settings screen), pushed on the same stack.
    case settingsFlow(SettingsFlowRoute)
    /// Blood tests: the list, one report, typed entry and lab clock entry (LV-08b.2).
    case labs
    case labReport(UUID)
    case labEntry
    case labClockEntry
    /// One catalog marker with every draw, from a year row or the star map (Data ICP R3: Blood as an area).
    case labMarker(LabMarkerKey)
    /// One number's method page (DEC-12.20).
    case method(MethodID)
    /// "How the numbers work": the list of every method page.
    case methods
    /// Publish a page: pick metrics and save a static HTML and JSON dashboard (DEC-12.19).
    case publish
}

struct MainTabLaunchState: Equatable {
    var tab: MainTab
    var healthPath: [AppHealthRoute] = []

    /// - Parameter afterUpdate: the first launch after the update from build 21. It opens on Today, where "What's new"
    ///   explains the new tabs, instead of a tab whose position moved under the person's thumb.
    static func restoring(_ raw: String?, afterUpdate: Bool) -> Self {
        afterUpdate ? .init(tab: .today) : restoring(raw)
    }

    static func restoring(_ raw: String?) -> Self {
        #if DEBUG
        if let path = MethodLaunchArgument.healthPath(ProcessInfo.processInfo.arguments) { return .init(tab: .data, healthPath: path) }
        #endif
        return switch raw {
        case "sleep": .init(tab: .data, healthPath: [.sleepHome])
        case "heart": .init(tab: .data, healthPath: [.heartHome])
        case "body": .init(tab: .data, healthPath: [.bodyHome])
        case "body-log": .init(tab: .data, healthPath: [.bodyHome, .bodyLog])
        case "workouts", "fitness": .init(tab: .fitness)
        case "protocol": .init(tab: .protocol)
        case "data": .init(tab: .data)
        case "labs": .init(tab: .data, healthPath: [.labs])
        case "publish": .init(tab: .data, healthPath: [.publish])
        default: .init(tab: raw.flatMap(MainTab.init(rawValue:)) ?? .today)
        }
    }

    /// The launch argument UI tests and captures use to open a screen, such as `--loopr-start-at=protocol-experiments`.
    static let startAtPrefix = "--loopr-start-at="

    private static func startAt(_ arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix(startAtPrefix) }.map { String($0.dropFirst(startAtPrefix.count)) }
    }

    /// The tab a `--loopr-start-at=` argument opens, or nil without one. `protocol-<segment>` opens Protocol; any other
    /// value reads as a saved tab name.
    static func startingAt(_ arguments: [String]) -> Self? {
        guard let raw = startAt(arguments) else { return nil }
        if raw.hasPrefix("protocol-") { return .init(tab: .protocol) }
        return restoring(raw)
    }

    /// The Protocol segment a start-at value names: `experiments` for `protocol-experiments`.
    static func protocolSegment(_ arguments: [String]) -> String? {
        guard let raw = startAt(arguments), raw.hasPrefix("protocol-") else { return nil }
        return String(raw.dropFirst("protocol-".count))
    }
}
