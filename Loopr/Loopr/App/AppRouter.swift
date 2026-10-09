import Observation
import Foundation
import BodyKit
import HeartKit
import JournalKit
import NotificationKit
import SettingsKit
import SleepKit
import StressKit
import TodayKit
import WorkoutKit

enum AppModalRoute: String, Identifiable, Hashable {
    case settings
    case activeWorkout
    #if DEBUG
    case designSystem
    case zoneCapture
    #endif

    var id: String { rawValue }

    var accessibilityIdentifier: String {
        switch self {
        case .settings: "settings-modal"
        case .activeWorkout: "active-workout-modal"
        #if DEBUG
        case .designSystem: "design-system-gallery"
        case .zoneCapture: "zone-capture"
        #endif
        }
    }
}

/// The shell owns navigation state, while each package owns the destination
/// view. Keeping the route graph typed makes deep links and accessibility
/// automation exercise the same paths as user taps.
enum AppRootRoute: Hashable {
    case tab(MainTab)
    case today(AppTodayRoute)
    case sleep(SleepKit.SleepRoute)
    case heart(HeartKit.HeartRoute)
    case body(BodyKit.BodyRoute)
    case workout(WorkoutKit.WorkoutRoute)
    case modal(AppModalRoute)
}

@MainActor
@Observable
final class AppRouter {
    var modal: AppModalRoute?

    func present(_ route: AppModalRoute) { modal = route }
    func dismiss() { modal = nil }
}

nonisolated enum ShellDeepLink: Equatable {
    case todayHome
    case breathing(start: Bool, bandPacing: Bool)
    case intervals
    case syncBand
    case todayDetail
    case sleepDetail
    case heartHome
    case heartDetail
    case heartTrends
    case bodyDetail
    case workoutsDetail
    #if DEBUG
    case zoneCapture
    #endif
    case habitInsights
    case habitSetup
    case habitManagement
    case habitHistory
    case habitDetail
    case habitCheckIn(String)
    case recordsDetail
    case recordsRecap
    case gestureMapping
    case coach
    case goals
    case stress
    case settings(SettingsRouteDestination)
    case workout(UUID?)
    case wakeAlarm
    case settingsHome

    init?(url: URL) {
        guard url.scheme?.lowercased() == "loopr" else { return nil }
        switch url.host?.lowercased() {
        case "today": self = .todayHome
        case "intervals": self = .intervals
        case "breathing":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            self = .breathing(start: items.first(where: { $0.name == "start" })?.value == "true",
                              bandPacing: items.first(where: { $0.name == "band" })?.value == "true")
        default: return nil
        }
    }

    init(notification link: NotificationDeepLink) {
        self = switch link {
        case .today: .todayDetail
        case .heart: .heartDetail
        case .goals: .goals
        case .workout(let identifier): .workout(UUID(uuidString: identifier))
        case .journal(let day):
            if day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
                .habitCheckIn(day)
            } else {
                .habitInsights
            }
        case .coach: .coach
        case .sleep: .sleepDetail
        case .hydration: .todayDetail
        case .device: .settings(.deviceCenter)
        case .stress: .stress
        case .cycle: .settings(.cycle)
        case .heartAlert: .settings(.heartAlerts)
        }
    }

    #if DEBUG
    static func parse(arguments: [String]) -> Self? {
        guard let raw = arguments.first(where: { $0.hasPrefix("--loopr-deep-link=") })?
            .dropFirst("--loopr-deep-link=".count) else { return nil }
        return switch raw {
        case "today/detail": .todayDetail
        case "today": .todayHome
        case "sleep", "sleep/detail": .sleepDetail
        case "heart": .heartHome
        case "heart/detail": .heartDetail
        case "phase06/heart-trends": .heartTrends
        case "body", "body/detail": .bodyDetail
        case "workouts/detail": .workoutsDetail
        case "workouts/zone2": .zoneCapture
        case "phase06/journal-correlations", "journal/habit-insights": .habitInsights
        case "journal/habit-setup": .habitSetup
        case "journal/habit-management": .habitManagement
        case "journal/habit-history": .habitHistory
        case "journal/habit-detail": .habitDetail
        case "journal/habit-check-in": .habitCheckIn(HabitFixtures.day.habitKey)
        case "phase06/records-detail": .recordsDetail
        case "phase06/records-recap": .recordsRecap
        case "phase06/gesture-mapping": .gestureMapping
        case "settings/heart-alerts": .settings(.heartAlerts)
        case "settings/notifications": .settings(.notifications)
        case "today/wake-alarm": .wakeAlarm
        case "settings": .settingsHome
        case "settings/wake-alarm": .settings(.wakeAlarm)
        case "settings/goals": .settings(.goals)
        case "today/stress": .stress
        case "today/breathing": .breathing(start: false, bandPacing: false)
        case "workouts/intervals": .intervals
        case "settings/device-center": .settings(.deviceCenter)
        case "settings/import-export": .settings(.importExport)
        default: nil
        }
    }
    #endif
}

let looprNotificationDeepLinkName = Notification.Name("com.loopr.notification.deep-link")

/// Root links select the owning tab. Breakdowns and metric pages still push.
enum TodayTabOwnership {
    static func tab(for route: TodayRoute) -> MainTab? {
        switch route {
        case .sleep: .sleep
        case .heart: .heart
        case .body: .body
        default: nil
        }
    }
}

enum AppHeartRoute: Hashable {
    case feature(HeartKit.HeartRoute)
    case stress(StressKit.StressRoute)
}
