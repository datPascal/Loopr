import AIKit
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
    case ask
    case yourData
    case activeWorkout
    #if DEBUG
    case designSystem
    case zoneCapture
    #endif

    var id: String { rawValue }

    var accessibilityIdentifier: String {
        switch self {
        case .settings: "settings-modal"
        case .ask: "ask-sheet"
        case .yourData: "your-data-screen"
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
    /// Where the Settings sheet opens. It lives beside `modal` so the sheet reads the path set with it; a separate
    /// `@State` in the shell reached a freshly presented sheet one update late, so "Add your age" opened the root.
    var settingsInitialPath: [SettingsFlowRoute] = []
    var settingsFocusAge = false

    func present(_ route: AppModalRoute) { modal = route }
    func dismiss() { modal = nil }
}

nonisolated enum ShellDeepLink: Equatable {
    case todayHome
    case dataHome, foodHome, fitnessHome, protocolHome
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
    /// A finished gym session's page, as its row on Fitness opens it. Debug links only.
    case trainSession(UUID)
    #if DEBUG
    case zoneCapture
    #endif
    case patterns
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
    /// A briefing notification: the coach opens this chat.
    case coachChat(UUID)
    case goals
    case stress
    case settings(SettingsRouteDestination)
    case workout(UUID?)
    case wakeAlarm
    case settingsHome
    /// A source button under an Ask answer. `MainTabShell+Agent.swift` maps it to a screen.
    case agentSource(AgentSourceLink)
    /// The weekly review sheet (LV-09.2), from its reminder or the Protocol tab.
    case weeklyReview
    /// The Protocol tab at its root, on one segment, such as Experiments from Today's experiment strip.
    case protocolSegment(ProtocolSegment)

    init?(url: URL) {
        guard url.scheme?.lowercased() == "loopr" else { return nil }
        switch url.host?.lowercased() {
        case "today": self = .todayHome
        // The tab names are the hosts from DEC-12.1. Every host build 21 shipped keeps working.
        case "health", "data": self = .dataHome
        case "food": self = .foodHome
        case "journal", "protocol": self = .protocolHome
        case "train", "workouts", "fitness":
            switch url.path {
            case "/detail": self = .workoutsDetail
            case "/intervals": self = .intervals
            default: self = .fitnessHome
            }
        case "sleep": self = .sleepDetail
        case "heart":
            switch url.path {
            case "/detail": self = .heartDetail
            case "/trends": self = .heartTrends
            default: self = .heartHome
            }
        case "body": self = .bodyDetail
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
        case .coach(let target): UUID(uuidString: target).map(Self.coachChat) ?? .coach
        case .sleep: .sleepDetail
        case .hydration: .todayDetail
        case .device: .settings(.deviceCenter)
        case .stress: .stress
        case .cycle: .settings(.cycle)
        case .heartAlert: .settings(.heartAlerts)
        // A reminder from Ask opens Ask. A Patterns test reminder opens Patterns.
        case .ask: .coach
        case .patterns: .patterns
        case .weeklyReview: .weeklyReview
        }
    }

    #if DEBUG
    static func parse(arguments: [String]) -> Self? {
        guard let raw = arguments.first(where: { $0.hasPrefix("--loopr-deep-link=") })?
            .dropFirst("--loopr-deep-link=".count) else { return nil }
        if raw.hasPrefix("workouts/session/"), let id = UUID(uuidString: String(raw.dropFirst("workouts/session/".count))) {
            return .trainSession(id)
        }
        if raw.hasPrefix("workouts/page/"), let id = UUID(uuidString: String(raw.dropFirst("workouts/page/".count))) {
            return .workout(id)
        }
        return switch raw {
        case "today/detail": .todayDetail
        case "today": .todayHome
        case "today/patterns", "patterns": .patterns
        case "today/goals": .goals
        case "health", "data": .dataHome
        case "food": .foodHome
        case "train", "workouts", "fitness": .fitnessHome
        case "journal", "protocol": .protocolHome
        case "protocol/experiments": .protocolSegment(.experiments)
        case "weekly-review": .weeklyReview
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
        case .sleep, .heart, .body: .data
        default: nil
        }
    }
}

enum AppHeartRoute: Hashable {
    case feature(HeartKit.HeartRoute)
    case stress(StressKit.StressRoute)
}
